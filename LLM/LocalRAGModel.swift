import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Observation
import Tokenizers

enum RAGEmbeddingChoice: String, CaseIterable, Identifiable {
    case multilingualE5
    case qwen3
    case embeddingGemma2

    var id: String { repositoryID }

    var repositoryID: String {
        switch self {
        case .multilingualE5:
            "intfloat/multilingual-e5-small"
        case .qwen3:
            "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
        case .embeddingGemma2:
            "mlx-community/embeddinggemma-2-4bit"
        }
    }

    var title: String {
        switch self {
        case .multilingualE5:
            "Multilingual E5 Small · çok dilli"
        case .qwen3:
            "Qwen3 Embedding 0.6B · 4-bit"
        case .embeddingGemma2:
            "EmbeddingGemma 2 · 4-bit (~1,1 GB)"
        }
    }

    var queryPrefix: String {
        switch self {
        case .multilingualE5:
            "query: "
        case .qwen3:
            "Instruct: Given a user question, retrieve relevant passages\nQuery: "
        case .embeddingGemma2:
            "task: search result | query: "
        }
    }

    var passagePrefix: String {
        switch self {
        case .multilingualE5:
            "passage: "
        case .qwen3:
            ""
        case .embeddingGemma2:
            "title: none | text: "
        }
    }
}

struct RAGEmbeddingComparison: Identifiable {
    var id: RAGEmbeddingChoice { choice }
    let choice: RAGEmbeddingChoice
    let results: [RAGScoredChunk]
}

@Observable
@MainActor
final class LocalRAGModel {
    var selectedEmbedding: RAGEmbeddingChoice = .multilingualE5
    var chunks: [RAGChunk] = []
    private var isProcessing = false
    var isManagingModels = false
    private(set) var isLoadingIndex = true
    var isBusy: Bool { isProcessing || isManagingModels || isLoadingIndex }
    var progress = 0.0
    var statusMessage: String?
    var errorMessage: String?
    var answer = ""
    var sources: [RAGChunk] = []
    var selectedSource: RAGChunk?
    var embeddingComparison: [RAGEmbeddingComparison] = []

    private var embedder: EmbedderModelContainer?
    private var loadedEmbeddingID: String?
    private let documentStore: RAGDocumentStore
    private let vectorIndex = RAGVectorIndex()
    private var loadTask: Task<Void, Never>?
    private let embeddingPreferenceKey = "rag.embeddingModel"

    var documents: [RAGDocumentSummary] {
        Dictionary(grouping: chunks, by: \.documentID).map { id, pieces in
            RAGDocumentSummary(id: id, name: pieces[0].sourceName, chunkCount: pieces.count)
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    var indexedChunkCount: Int {
        chunks.filter { $0.embedding != nil }.count
    }

    var hasUnembeddedChunks: Bool {
        chunks.contains { $0.embedding == nil }
    }

    init(documentReader: any RAGDocumentReading = RAGDocumentReader(), directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        documentStore = RAGDocumentStore(directory: directory, reader: documentReader)
        if let storedChoice = UserDefaults.standard.string(forKey: embeddingPreferenceKey),
           let choice = RAGEmbeddingChoice(rawValue: storedChoice) {
            selectedEmbedding = choice
        }
        loadTask = Task { [weak self, documentStore] in
            do {
                let saved = try await documentStore.load()
                self?.chunks = saved
            } catch {
                self?.errorMessage = "Kaydedilmiş belge indeksi açılamadı: \(error.localizedDescription)"
            }
            self?.isLoadingIndex = false
        }
    }

    func waitUntilLoaded() async { await loadTask?.value }

    func selectEmbedding(_ choice: RAGEmbeddingChoice) async {
        guard choice != selectedEmbedding, !isBusy else { return }
        isProcessing = true
        defer { isProcessing = false }
        var updated = chunks
        for index in updated.indices { updated[index].embedding = nil }
        do {
            try await documentStore.save(updated)
            chunks = updated
            selectedEmbedding = choice
            UserDefaults.standard.set(choice.rawValue, forKey: embeddingPreferenceKey)
            unloadEmbedder()
        } catch {
            errorMessage = "İndeks kaydedilemedi: \(error.localizedDescription)"
        }
    }

    func unloadEmbedder() {
        let hadModel = embedder != nil
        embedder = nil
        loadedEmbeddingID = nil
        if hadModel { MLXRuntimeSupport.clearCache() }
    }

    func importDocuments(from urls: [URL]) async {
        guard !isBusy else { return }
        errorMessage = nil
        answer = ""
        sources = []
        isProcessing = true
        statusMessage = "Belgeler okunuyor…"
        defer {
            isProcessing = false
            statusMessage = nil
            progress = 0
        }

        do {
            chunks = try await documentStore.importing(urls, into: chunks)
            statusMessage = "\(urls.count) belge eklendi. Sorular için önce indeks oluştur."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func indexDocuments(using chat: LocalChatModel) async {
        guard !isBusy, !chat.isBusy else { return }
        guard requireEmbeddingRuntime() else { return }
        guard hasUnembeddedChunks else { return }
        errorMessage = nil
        isProcessing = true
        progress = 0
        defer {
            unloadEmbedder()
            isProcessing = false
            statusMessage = nil
            progress = 0
        }

        do {
            chat.unloadModel()
            MLXRuntimeSupport.clearCache()
            try await loadEmbedderIfNeeded()
            let pendingIndices = chunks.indices.filter { chunks[$0].embedding == nil }
            for (completed, index) in pendingIndices.enumerated() {
                statusMessage = completed == 0 ? "Embedding modeli hazırlanıyor…" : "Belgeler indeksleniyor…"
                let vector = try await makeEmbedding(for: chunks[index].text, isQuery: false)
                chunks[index].embedding = vector
                progress = Double(completed + 1) / Double(pendingIndices.count)
                if completed.isMultiple(of: 8) {
                    try await persistIndex()
                    MLXRuntimeSupport.clearCache()
                }
            }
            try await persistIndex()
            statusMessage = "\(chunks.count) metin parçası indekslendi."
        } catch {
            errorMessage = error.localizedDescription
            do {
                try await persistIndex()
            } catch {
                errorMessage = "\(errorMessage ?? "İndeks oluşturulamadı.") İndeks diske kaydedilemedi: \(error.localizedDescription)"
            }
        }
    }

    func ask(
        _ question: String,
        using chat: LocalChatModel,
        history: ConversationHistoryStore
    ) async {
        guard !isBusy, !chat.isBusy else { return }
        guard requireEmbeddingRuntime() else { return }
        guard indexedChunkCount > 0 else {
            errorMessage = "Önce belge ekleyip embedding indeksini oluşturun."
            return
        }
        errorMessage = nil
        answer = ""
        sources = []
        let startedAt = ProcessInfo.processInfo.systemUptime
        isProcessing = true
        statusMessage = "İlgili belge parçaları aranıyor…"
        defer {
            unloadEmbedder()
            isProcessing = false
            statusMessage = nil
        }

        do {
            chat.unloadModel()
            MLXRuntimeSupport.clearCache()
            try await loadEmbedderIfNeeded()
            let queryVector = try await makeEmbedding(for: question, isQuery: true)
            let matches = try await vectorIndex.rank(query: queryVector, chunks: chunks).map(\.chunk)

            guard !matches.isEmpty else {
                throw LocalRAGError.noRelevantChunks
            }
            sources = matches
            let context = matches.enumerated().map { index, chunk in
                "[Kaynak \(index + 1): \(chunk.sourceName)]\n\(chunk.text)"
            }.joined(separator: "\n\n")

            unloadEmbedder()
            statusMessage = "Seçili dil modeli yanıt hazırlıyor…"
            let completion = try await chat.answerWithContext(
                question: question,
                context: context,
                startedAt: startedAt
            )
            answer = completion.text
            history.add(
                kind: .rag,
                title: question,
                prompt: question,
                answer: answer,
                details: matches.enumerated().map { index, chunk in
                    "[\(index + 1)] \(chunk.sourceName)\n\(chunk.text)"
                }.joined(separator: "\n\n"),
                modelName: chat.selectedModel.title,
                totalDurationSeconds: completion.totalDurationSeconds,
                firstResponseSeconds: completion.firstResponseSeconds
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func compareEmbeddings(
        for question: String,
        choices: [RAGEmbeddingChoice],
        using chat: LocalChatModel
    ) async {
        guard !isBusy, !chat.isBusy else { return }
        guard requireEmbeddingRuntime() else { return }
        guard choices.count == 2, choices[0] != choices[1] else {
            errorMessage = "Karşılaştırmak için iki farklı embedding modeli seçin."
            return
        }
        guard !chunks.isEmpty else {
            errorMessage = "Karşılaştırmadan önce belge ekleyin."
            return
        }

        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            errorMessage = "Karşılaştırma için bir soru yazın."
            return
        }

        errorMessage = nil
        embeddingComparison = []
        isProcessing = true
        progress = 0
        defer {
            unloadEmbedder()
            isProcessing = false
            statusMessage = nil
            progress = 0
        }

        do {
            chat.unloadModel()
            MLXRuntimeSupport.clearCache()

            var comparisons: [RAGEmbeddingComparison] = []
            for (index, choice) in choices.enumerated() {
                statusMessage = "\(choice.title) ile arama yapılıyor…"
                try await loadEmbedderIfNeeded(for: choice)
                let queryVector = try await makeEmbedding(
                    for: trimmedQuestion,
                    isQuery: true,
                    using: choice
                )
                var scoredChunks: [RAGScoredChunk] = []
                for (offset, chunk) in chunks.enumerated() {
                    let vector = try await makeEmbedding(
                        for: chunk.text,
                        isQuery: false,
                        using: choice
                    )
                    guard let score = RAGVectorIndex.cosineSimilarity(queryVector, vector) else { continue }
                    progress = (Double(index) + Double(offset + 1) / Double(chunks.count)) / 2
                    scoredChunks.append(RAGScoredChunk(chunk: chunk, score: score))
                }
                comparisons.append(
                    RAGEmbeddingComparison(
                        choice: choice,
                        results: scoredChunks.sorted { $0.score > $1.score }.prefix(3).map { $0 }
                    )
                )
                unloadEmbedder()
            }
            embeddingComparison = comparisons
            statusMessage = "Karşılaştırma tamamlandı."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeDocument(id: String) async {
        guard !isBusy else { return }
        isProcessing = true
        defer { isProcessing = false }
        do {
            chunks = try await documentStore.removing(documentID: id, from: chunks)
            sources.removeAll { $0.documentID == id }
            if selectedSource?.documentID == id { selectedSource = nil }
            embeddingComparison = []
            answer = ""
        } catch {
            errorMessage = "Belge indeksi kaydedilemedi: \(error.localizedDescription)"
        }
    }

    var sourceDirectory: URL { documentStore.sourceDirectory }

    func sourceURL(for chunk: RAGChunk) -> URL? {
        guard let storedName = chunk.sourceStorageName else { return nil }
        let url = sourceDirectory.appendingPathComponent(storedName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func requireEmbeddingRuntime() -> Bool {
        guard MLXRuntimeSupport.isSupported else {
            errorMessage = LocalChatError.simulatorNotSupported.localizedDescription
            return false
        }
        return true
    }

    private func loadEmbedderIfNeeded(for choice: RAGEmbeddingChoice? = nil) async throws {
        try MLXRuntimeSupport.requireSupported()
        let choice = choice ?? selectedEmbedding
        guard loadedEmbeddingID != choice.id else { return }
        unloadEmbedder()
        statusMessage = "\(choice.title) indiriliyor ve yükleniyor…"
        let loaded = try await EmbedderModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: choice.repositoryID),
            progressHandler: { [weak self] progress in
                let fractionCompleted = progress.fractionCompleted
                guard let self else { return }
                Task { @MainActor in
                    self.progress = min(max(fractionCompleted, 0), 1)
                }
            }
        )
        embedder = loaded
        loadedEmbeddingID = choice.id
    }

    private func makeEmbedding(
        for text: String,
        isQuery: Bool,
        using choice: RAGEmbeddingChoice? = nil
    ) async throws -> [Float] {
        guard let embedder else {
            throw LocalRAGError.embedderUnavailable
        }
        let choice = choice ?? selectedEmbedding
        let prefix = isQuery ? choice.queryPrefix : choice.passagePrefix
        return try await embedder.perform { context in
            let tokenIDs = context.tokenizer.encode(
                text: prefix + text,
                addSpecialTokens: true
            )
            guard !tokenIDs.isEmpty else {
                throw LocalRAGError.tokenizationFailed
            }

            let inputs = stacked([MLXArray(tokenIDs)])
            let output = context.model(
                inputs,
                positionIds: nil,
                tokenTypeIds: nil,
                attentionMask: nil
            )
            let vector = context.pooling(output, normalize: true)
            vector.eval()
            return vector[0].asArray(Float.self)
        }
    }

    private func persistIndex() async throws {
        try await documentStore.save(chunks)
    }


}

private enum LocalRAGError: LocalizedError {
    case emptyDocument(String)
    case embedderUnavailable
    case tokenizationFailed
    case noRelevantChunks

    var errorDescription: String? {
        switch self {
        case .emptyDocument(let name):
            "\(name) dosyasından metin çıkarılamadı."
        case .embedderUnavailable:
            "Embedding modeli kullanılamıyor. Lütfen yeniden indeksleyin."
        case .tokenizationFailed:
            "Metin embedding modeli için hazırlanamadı."
        case .noRelevantChunks:
            "Soruyla eşleşen belge parçası bulunamadı."
        }
    }
}
