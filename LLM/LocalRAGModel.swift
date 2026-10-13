import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Observation
import PDFKit
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

struct RAGChunk: Codable, Identifiable {
    var id: UUID
    var sourceName: String
    var text: String
    var embedding: [Float]?
    var sourceStorageName: String?
    var pageNumber: Int?
}

struct RAGScoredChunk: Identifiable {
    var id: UUID { chunk.id }
    let chunk: RAGChunk
    let score: Float
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
    var isBusy = false
    var progress = 0.0
    var statusMessage: String?
    var errorMessage: String?
    var answer = ""
    var sources: [RAGChunk] = []
    var selectedSource: RAGChunk?
    var embeddingComparison: [RAGEmbeddingComparison] = []

    private var embedder: EmbedderModelContainer?
    private var loadedEmbeddingID: String?
    private let indexURL: URL
    private let embeddingPreferenceKey = "rag.embeddingModel"

    var documentNames: [String] {
        Array(Set(chunks.map(\.sourceName))).sorted()
    }

    var indexedChunkCount: Int {
        chunks.filter { $0.embedding != nil }.count
    }

    var hasUnembeddedChunks: Bool {
        chunks.contains { $0.embedding == nil }
    }

    init() {
        if let storedChoice = UserDefaults.standard.string(forKey: embeddingPreferenceKey),
           let choice = RAGEmbeddingChoice(rawValue: storedChoice) {
            selectedEmbedding = choice
        }
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        indexURL = documentsURL.appendingPathComponent("rag-index.json")
        do {
            let data = try Data(contentsOf: indexURL)
            chunks = try JSONDecoder().decode([RAGChunk].self, from: data)
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                errorMessage = "Kaydedilmiş belge indeksi açılamadı: \(error.localizedDescription)"
            }
        }
    }

    func selectEmbedding(_ choice: RAGEmbeddingChoice) {
        guard choice != selectedEmbedding, !isBusy else { return }
        selectedEmbedding = choice
        UserDefaults.standard.set(choice.rawValue, forKey: embeddingPreferenceKey)
        unloadEmbedder()
        for index in chunks.indices {
            chunks[index].embedding = nil
        }
        do {
            try persistIndex()
        } catch {
            errorMessage = "İndeks kaydedilemedi: \(error.localizedDescription)"
        }
    }

    func unloadEmbedder() {
        embedder = nil
        loadedEmbeddingID = nil
        Memory.clearCache()
    }

    func importDocuments(from urls: [URL]) async {
        guard !isBusy else { return }
        errorMessage = nil
        answer = ""
        sources = []
        isBusy = true
        statusMessage = "Belgeler okunuyor…"
        defer {
            isBusy = false
            statusMessage = nil
            progress = 0
        }

        do {
            var newChunks: [RAGChunk] = []
            let sourceDirectory = documentsDirectory.appendingPathComponent("rag-source-files", isDirectory: true)
            try FileManager.default.createDirectory(
                at: sourceDirectory,
                withIntermediateDirectories: true
            )
            for url in urls {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let storedName = "\(UUID().uuidString).\(url.pathExtension)"
                let storedURL = sourceDirectory.appendingPathComponent(storedName)
                let pages = try extractPages(from: url)
                let pieces = pages.flatMap { page in
                    Self.split(page.text, maximumLength: 850, overlap: 120).map {
                        (text: $0, pageNumber: page.pageNumber)
                    }
                }
                guard !pieces.isEmpty else {
                    throw LocalRAGError.emptyDocument(url.lastPathComponent)
                }
                try FileManager.default.copyItem(at: url, to: storedURL)
                newChunks.append(contentsOf: pieces.map {
                    RAGChunk(
                        id: UUID(),
                        sourceName: url.lastPathComponent,
                        text: $0.text,
                        embedding: nil,
                        sourceStorageName: storedName,
                        pageNumber: $0.pageNumber
                    )
                })
            }
            guard !newChunks.isEmpty else { return }
            chunks.append(contentsOf: newChunks)
            try persistIndex()
            statusMessage = "\(urls.count) belge eklendi. Sorular için önce indeks oluştur."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func indexDocuments(using chat: LocalChatModel) async {
        guard !isBusy, !chat.isBusy, hasUnembeddedChunks else { return }
        errorMessage = nil
        isBusy = true
        progress = 0
        defer {
            unloadEmbedder()
            isBusy = false
            statusMessage = nil
            progress = 0
        }

        do {
            chat.unloadModel()
            Memory.clearCache()
            try await loadEmbedderIfNeeded()
            let pendingIndices = chunks.indices.filter { chunks[$0].embedding == nil }
            for (completed, index) in pendingIndices.enumerated() {
                statusMessage = completed == 0 ? "Embedding modeli hazırlanıyor…" : "Belgeler indeksleniyor…"
                let vector = try await makeEmbedding(for: chunks[index].text, isQuery: false)
                chunks[index].embedding = vector
                progress = Double(completed + 1) / Double(pendingIndices.count)
                if completed.isMultiple(of: 8) {
                    try persistIndex()
                    Memory.clearCache()
                }
            }
            try persistIndex()
            statusMessage = "\(chunks.count) metin parçası indekslendi."
        } catch {
            errorMessage = error.localizedDescription
            do {
                try persistIndex()
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
        guard indexedChunkCount > 0 else {
            errorMessage = "Önce belge ekleyip embedding indeksini oluşturun."
            return
        }
        errorMessage = nil
        answer = ""
        sources = []
        let startedAt = ProcessInfo.processInfo.systemUptime
        isBusy = true
        statusMessage = "İlgili belge parçaları aranıyor…"
        defer {
            unloadEmbedder()
            isBusy = false
            statusMessage = nil
        }

        do {
            chat.unloadModel()
            Memory.clearCache()
            try await loadEmbedderIfNeeded()
            let queryVector = try await makeEmbedding(for: question, isQuery: true)
            let matches = chunks
                .compactMap { chunk -> (RAGChunk, Float)? in
                    guard let embedding = chunk.embedding else { return nil }
                    return (chunk, Self.cosineSimilarity(queryVector, embedding))
                }
                .sorted { $0.1 > $1.1 }
                .prefix(4)
                .map(\.0)

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
        isBusy = true
        progress = 0
        defer {
            unloadEmbedder()
            isBusy = false
            statusMessage = nil
            progress = 0
        }

        do {
            chat.unloadModel()
            Memory.clearCache()

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
                    let score = Self.cosineSimilarity(queryVector, vector)
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

    func removeDocument(named name: String) {
        guard !isBusy else { return }
        let sourceNames = Set(chunks.filter { $0.sourceName == name }.compactMap(\.sourceStorageName))
        chunks.removeAll { $0.sourceName == name }
        do {
            try persistIndex()
            for sourceName in sourceNames {
                let url = sourceDirectory.appendingPathComponent(sourceName)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            errorMessage = "Belge indeksi kaydedilemedi: \(error.localizedDescription)"
        }
    }

    var sourceDirectory: URL {
        documentsDirectory.appendingPathComponent("rag-source-files", isDirectory: true)
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func sourceURL(for chunk: RAGChunk) -> URL? {
        guard let storedName = chunk.sourceStorageName else { return nil }
        let url = sourceDirectory.appendingPathComponent(storedName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func loadEmbedderIfNeeded(for choice: RAGEmbeddingChoice? = nil) async throws {
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

    private func extractPages(from url: URL) throws -> [(text: String, pageNumber: Int?)] {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else {
                throw LocalRAGError.cannotReadDocument(url.lastPathComponent)
            }
            return (0..<document.pageCount).compactMap { index in
                guard let text = document.page(at: index)?.string else { return nil }
                return (text: text, pageNumber: index + 1)
            }
        case "txt", "md", "markdown":
            return [(text: try String(contentsOf: url, encoding: .utf8), pageNumber: nil)]
        case "rtf":
            let data = try Data(contentsOf: url)
            let text = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ).string
            return [(text: text, pageNumber: nil)]
        default:
            throw LocalRAGError.unsupportedDocument(url.lastPathComponent)
        }
    }

    private func persistIndex() throws {
        let data = try JSONEncoder().encode(chunks)
        try data.write(to: indexURL, options: .atomic)
    }

    private static func split(_ text: String, maximumLength: Int, overlap: Int) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maximumLength, limitedBy: text.endIndex) ?? text.endIndex
            let piece = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                result.append(piece)
            }
            guard end < text.endIndex else { break }
            start = text.index(end, offsetBy: -overlap, limitedBy: text.startIndex) ?? text.startIndex
            if start == text.startIndex {
                start = end
            }
        }
        return result
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        let dot = zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        let lhsNorm = sqrt(lhs.reduce(Float.zero) { $0 + $1 * $1 })
        let rhsNorm = sqrt(rhs.reduce(Float.zero) { $0 + $1 * $1 })
        guard lhsNorm > 0, rhsNorm > 0 else { return -1 }
        return dot / (lhsNorm * rhsNorm)
    }
}

private enum LocalRAGError: LocalizedError {
    case emptyDocument(String)
    case cannotReadDocument(String)
    case unsupportedDocument(String)
    case embedderUnavailable
    case tokenizationFailed
    case noRelevantChunks

    var errorDescription: String? {
        switch self {
        case .emptyDocument(let name):
            "\(name) dosyasından metin çıkarılamadı."
        case .cannotReadDocument(let name):
            "\(name) PDF dosyası açılamadı."
        case .unsupportedDocument(let name):
            "\(name) desteklenmiyor. PDF, TXT, Markdown veya RTF seçin."
        case .embedderUnavailable:
            "Embedding modeli kullanılamıyor. Lütfen yeniden indeksleyin."
        case .tokenizationFailed:
            "Metin embedding modeli için hazırlanamadı."
        case .noRelevantChunks:
            "Soruyla eşleşen belge parçası bulunamadı."
        }
    }
}
