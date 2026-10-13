import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers
import AVFoundation
import Speech

enum LocalModelChoice: String, CaseIterable, Identifiable {
    case qwen
    case gemma
    case gemma4
    case qwen35

    var id: String {
        repositoryID
    }

    var repositoryID: String {
        switch self {
        case .qwen:
            "mlx-community/Qwen3-0.6B-4bit"
        case .gemma:
            "mlx-community/gemma-3-1b-it-4bit"
        case .gemma4:
            "over-show/gemma-4-e2b-it-text-only-4bit"
        case .qwen35:
            "bobkitchen/Qwen3.5-2B-Text-4bit"
        }
    }

    var title: String {
        switch self {
        case .qwen:
            "Qwen 3 · 0.6B"
        case .gemma:
            "Gemma 3 · 1B"
        case .gemma4:
        "Gemma 4 E2B · 4-bit · ~2,5 GB"
        case .qwen35:
        "Qwen 3.5 · 2B · 4-bit · ~1 GB"
        }
    }

    var shortTitle: String {
        switch self {
        case .qwen:
            "Qwen 3"
        case .gemma:
            "Gemma 3"
        case .gemma4:
            "Gemma 4 E2B"
        case .qwen35:
            "Qwen 3.5 2B"
        }
    }

    var configuration: ModelConfiguration {
        switch self {
        case .gemma4:
            ModelConfiguration(
                id: repositoryID,
                extraEOSTokens: ["<turn|>"]
            )
        case .qwen35:
            ModelConfiguration(
                id: repositoryID,
                extraEOSTokens: ["<|im_end|>"]
            )
        case .qwen, .gemma:
            ModelConfiguration(id: repositoryID)
        }
    }
}

struct LocalChatMessage: Codable, Identifiable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct ChatGenerationResult {
    var text: String
    var totalDurationSeconds: Double
    var firstResponseSeconds: Double
}

@Observable
@MainActor
final class LocalChatModel {
    var selectedModel: LocalModelChoice = .qwen
    var messages: [LocalChatMessage] = []
    var isBusy = false
    var isLoadingModel = false
    var isGenerating = false
    var downloadProgress = 0.0
    var errorMessage: String?
    var activeThreadTitle = "Yeni sohbet"
    private var conversationSummary: String?
    private var summarizedMessageCount = 0

    private var loadedModelID: String?
    private var modelContainer: ModelContainer?
    private var session: ChatSession?
    private weak var historyStore: ConversationHistoryStore?
    private var activeThreadID: UUID?

    func select(_ model: LocalModelChoice) {
        guard model != selectedModel, !isBusy else { return }
        selectedModel = model
        persistThread()
        session = nil
        downloadProgress = 0
    }

    func attachHistory(_ store: ConversationHistoryStore) {
        guard historyStore == nil else { return }
        historyStore = store
        if let id = store.activeThreadID, let thread = store.thread(id: id) {
            load(thread)
        } else {
            createThread()
        }
    }

    func createThread() {
        guard !isBusy, let historyStore else { return }
        let thread = historyStore.createThread(modelID: selectedModel.rawValue)
        load(thread)
    }

    func selectThread(_ thread: ChatThread) {
        guard !isBusy else { return }
        persistThread()
        load(thread)
    }

    func deleteThread(_ thread: ChatThread) {
        guard !isBusy, let historyStore else { return }
        historyStore.deleteThread(thread)
        if activeThreadID == thread.id {
            if let next = historyStore.threads.first {
                load(next)
            } else {
                createThread()
            }
        }
    }

    private func load(_ thread: ChatThread) {
        guard let model = LocalModelChoice(rawValue: thread.modelID) else { return }
        activeThreadID = thread.id
        activeThreadTitle = thread.title
        selectedModel = model
        messages = thread.messages
        conversationSummary = thread.summary
        summarizedMessageCount = thread.summarizedMessageCount
        session = nil
        unloadModel()
        historyStore?.setActiveThread(thread.id)
    }

    private func persistThread() {
        guard let activeThreadID else { return }
        historyStore?.updateThread(
            id: activeThreadID,
            modelID: selectedModel.rawValue,
            messages: messages,
            summary: conversationSummary,
            summarizedMessageCount: summarizedMessageCount
        )
        activeThreadTitle = historyStore?.thread(id: activeThreadID)?.title ?? activeThreadTitle
    }

    func unloadModel() {
        guard !isBusy else { return }
        session = nil
        modelContainer = nil
        loadedModelID = nil
        downloadProgress = 0
    }

    func releaseModelForSpeech() {
        unloadModel()
        Memory.clearCache()
    }

    func send(_ prompt: String, onToken: (String) -> Void = { _ in }) async -> ChatGenerationResult? {
        guard !isBusy else { return nil }
        errorMessage = nil

        #if targetEnvironment(simulator)
        errorMessage = LocalChatError.simulatorNotSupported.localizedDescription
        return nil
        #endif

        let startedAt = ProcessInfo.processInfo.systemUptime
        var firstResponseSeconds: Double?
        let answerID = UUID()
        messages.append(LocalChatMessage(role: .user, text: prompt))
        messages.append(LocalChatMessage(id: answerID, role: .assistant, text: ""))
        let priorMessages = Array(messages.dropLast(2))
        isBusy = true
        defer {
            isBusy = false
            isLoadingModel = false
            isGenerating = false
        }

        do {
            try await compactOlderHistoryIfNeeded(priorMessages)
            try await prepareSession(startFreshSession: true)
            let contextualPrompt = Self.promptWithHistory(
                conversationSummary,
                messages: Array(priorMessages.suffix(8)),
                prompt: prompt
            )
            let answer = try await generate(contextualPrompt) { token in
                if firstResponseSeconds == nil {
                    firstResponseSeconds = ProcessInfo.processInfo.systemUptime - startedAt
                }
                guard let answerIndex = messages.firstIndex(where: { $0.id == answerID }) else {
                    return
                }
                messages[answerIndex].text += token
                onToken(token)
            }

            if let answerIndex = messages.firstIndex(where: { $0.id == answerID }) {
                messages[answerIndex].text = answer
            }
            persistThread()
            return ChatGenerationResult(
                text: answer,
                totalDurationSeconds: ProcessInfo.processInfo.systemUptime - startedAt,
                firstResponseSeconds: firstResponseSeconds ?? ProcessInfo.processInfo.systemUptime - startedAt
            )
        } catch {
            messages.removeAll { $0.id == answerID }
            persistThread()
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func answerWithContext(
        question: String,
        context: String,
        startedAt: TimeInterval? = nil
    ) async throws -> ChatGenerationResult {
        guard !isBusy else { throw LocalChatError.modelBusy }
        errorMessage = nil

        #if targetEnvironment(simulator)
        throw LocalChatError.simulatorNotSupported
        #endif

        let requestStartedAt = startedAt ?? ProcessInfo.processInfo.systemUptime
        var firstResponseSeconds: Double?
        isBusy = true
        defer {
            isBusy = false
            isLoadingModel = false
            isGenerating = false
            session = nil
        }

        do {
            try await prepareSession(startFreshSession: true)
            isGenerating = true
            let prompt = """
            Yanıtını yalnızca aşağıdaki bağlama dayandır. Bağlamda yanıt yoksa bunu açıkça söyle.

            Bağlam:
            \(context)

            Soru: \(question)
            """
            let answer = try await generate(prompt) { _ in
                if firstResponseSeconds == nil {
                    firstResponseSeconds = ProcessInfo.processInfo.systemUptime - requestStartedAt
                }
            }
            return ChatGenerationResult(
                text: answer,
                totalDurationSeconds: ProcessInfo.processInfo.systemUptime - requestStartedAt,
                firstResponseSeconds: firstResponseSeconds ?? ProcessInfo.processInfo.systemUptime - requestStartedAt
            )
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func prepareSession(startFreshSession: Bool = false) async throws {
        if loadedModelID != selectedModel.id {
            isLoadingModel = true
            downloadProgress = 0

            let loadedContainer = try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: selectedModel.configuration,
                progressHandler: { [weak self] progress in
                    let fractionCompleted = progress.fractionCompleted
                    guard let self else { return }
                    Task { @MainActor in
                        self.downloadProgress = min(max(fractionCompleted, 0), 1)
                    }
                }
            )

            modelContainer = loadedContainer
            loadedModelID = selectedModel.id
        }

        if startFreshSession || session == nil {
            guard let modelContainer else {
                throw LocalChatError.sessionUnavailable
            }
            let isLargeModel = selectedModel == .gemma4
            session = ChatSession(
                modelContainer,
                instructions: "Türkçe konuşan, açık ve yardımcı bir asistansın.",
                generateParameters: GenerateParameters(
                    maxTokens: isLargeModel ? 256 : 384,
                    maxKVSize: isLargeModel ? 512 : 1024,
                    temperature: 0.6
                )
            )
        }
        isLoadingModel = false
    }

    private func compactOlderHistoryIfNeeded(_ messages: [LocalChatMessage]) async throws {
        guard messages.count - summarizedMessageCount > 12 else { return }
        let endIndex = max(summarizedMessageCount, messages.count - 8)
        guard endIndex > summarizedMessageCount else { return }

        let olderMessages = messages[summarizedMessageCount..<endIndex]
        let transcript = olderMessages.map { message in
            let content = String(message.text.prefix(900))
            return "\(message.role == .user ? "Kullanıcı" : "Asistan"): \(content)"
        }.joined(separator: "\n")
        let summaryPrompt = """
        Aşağıdaki konuşma geçmişini, sonraki yanıtlarda hatırlanması gereken bilgiler için kısa bir not olarak özetle.
        Kullanıcının tercihlerini, kişi/konu adlarını, önemli kararları ve açık kalan istekleri koru.
        Yalnızca özeti yaz; en fazla 180 kelime kullan.

        Önceki not:
        \(conversationSummary ?? "Yok")

        Yeni konuşma bölümü:
        \(transcript)
        """

        try await prepareSession(startFreshSession: true)
        let updatedSummary = try await generate(summaryPrompt) { _ in }
        conversationSummary = updatedSummary
        summarizedMessageCount = endIndex
        session = nil
    }

    private static func promptWithHistory(
        _ summary: String?,
        messages: [LocalChatMessage],
        prompt: String
    ) -> String {
        guard summary != nil || !messages.isEmpty else { return prompt }
        let transcript = messages.map { message in
            "\(message.role == .user ? "Kullanıcı" : "Asistan"): \(message.text)"
        }.joined(separator: "\n")
        return """
        \(summary.map { "Konuşmanın önceki bölümlerinden hatırlanacak not:\n\($0)\n\n" } ?? "")
        Son konuşma:
        \(transcript.isEmpty ? "Henüz mesaj yok." : transcript)

        Kullanıcının yeni mesajı:
        \(prompt)
        """
    }

    private func generate(
        _ prompt: String,
        onToken: (String) -> Void
    ) async throws -> String {
        guard let session else {
            throw LocalChatError.sessionUnavailable
        }

        isGenerating = true
        var response = ""
        for try await token in session.streamResponse(to: prompt) {
            response += token
            onToken(token)
        }
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalChatError.emptyResponse
        }
        return response
    }
}

enum LocalChatError: LocalizedError {
    case simulatorNotSupported
    case sessionUnavailable
    case emptyResponse
    case modelBusy

    var errorDescription: String? {
        switch self {
        case .simulatorNotSupported:
            "Yerel model çalıştırmak için uygulamayı fiziksel bir iPhone veya iPad'de açın."
        case .sessionUnavailable:
            "Model oturumu başlatılamadı. Lütfen tekrar deneyin."
        case .emptyResponse:
            "Model boş bir yanıt üretti. Lütfen sorunuzu yeniden deneyin."
        case .modelBusy:
            "Model şu anda başka bir yanıt hazırlıyor. Lütfen bekleyin."
        }
    }
}
