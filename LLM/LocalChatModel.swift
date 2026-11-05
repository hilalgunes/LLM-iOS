import Foundation
import Observation

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

    private let modelSession: any ModelSessionServing

    init(modelSession: (any ModelSessionServing)? = nil) {
        self.modelSession = modelSession ?? LocalModelSessionService()
    }

    private weak var historyStore: ConversationHistoryStore?
    private var activeThreadID: UUID?

    func select(_ model: LocalModelChoice) {
        guard model != selectedModel, !isBusy else { return }
        selectedModel = model
        persistThread()
        modelSession.resetConversation()
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
        modelSession.resetConversation()
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
        modelSession.unload()
        downloadProgress = 0
    }

    func releaseModelForSpeech() async {
        guard !isBusy else { return }
        await modelSession.releaseForSpeech()
        downloadProgress = 0
    }

    func send(_ prompt: String, onToken: (String) -> Void = { _ in }) async -> ChatGenerationResult? {
        guard !isBusy else { return nil }
        errorMessage = nil

        #if targetEnvironment(simulator)
        if selectedModel != .apple {
            errorMessage = LocalChatError.simulatorNotSupported.localizedDescription
            return nil
        }
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
        if selectedModel != .apple { throw LocalChatError.simulatorNotSupported }
        #endif

        let requestStartedAt = startedAt ?? ProcessInfo.processInfo.systemUptime
        var firstResponseSeconds: Double?
        isBusy = true
        defer {
            isBusy = false
            isLoadingModel = false
            isGenerating = false
            modelSession.resetConversation()
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
        isLoadingModel = true
        defer { isLoadingModel = false }
        try await modelSession.prepare(model: selectedModel, startFreshSession: startFreshSession) { [weak self] progress in
            self?.downloadProgress = progress
        }
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
        modelSession.resetConversation()
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

    private func generate(_ prompt: String, onToken: (String) -> Void) async throws -> String {
        isGenerating = true
        defer { isGenerating = false }
        return try await modelSession.generate(prompt, model: selectedModel, onToken: onToken)
    }

}

enum LocalChatError: LocalizedError {
    case simulatorNotSupported
    case sessionUnavailable
    case emptyResponse
    case modelBusy
    case systemModelUnavailable

    var errorDescription: String? {
        switch self {
        case .simulatorNotSupported:
            "Yerel model çalıştırmak için uygulamayı fiziksel bir iPhone veya iPad'de açın."
        case .sessionUnavailable:
            "Model oturumu başlatılamadı. Lütfen tekrar deneyin."
        case .emptyResponse:
            "Model boş bir yanıt üretti. Lütfen sorunuzu yeniden deneyin."
        case .systemModelUnavailable:
            "Apple Intelligence sistem modeli bu cihazda kullanılamıyor. Ayarlar’dan Apple Intelligence durumunu kontrol edin veya bir MLX modeli seçin."
        case .modelBusy:
            "Model şu anda başka bir yanıt hazırlıyor. Lütfen bekleyin."
        }
    }
}
