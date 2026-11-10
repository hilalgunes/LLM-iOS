import XCTest
@testable import LLM

@MainActor
final class LocalChatModelTests: XCTestCase {
    func testStreamsThroughInjectedSession() async {
        let session = StubModelSession()
        let chat = LocalChatModel(modelSession: session)
        chat.select(.apple)
        var deltas: [String] = []
        let result = await chat.send("Merhaba") { deltas.append($0) }
        XCTAssertEqual(result?.text, "Merhaba")
        XCTAssertEqual(deltas, ["Mer", "haba"])
        XCTAssertEqual(chat.messages.map(\.text), ["Merhaba", "Merhaba"])
        XCTAssertEqual(session.preparedModels, [.apple])
        XCTAssertEqual(chat.downloadProgress, 1)
        XCTAssertFalse(chat.isBusy)
        XCTAssertFalse(chat.isLoadingModel)
        XCTAssertFalse(chat.isGenerating)
    }

    func testPreparationFailureClearsLoadingAndAllowsRetry() async {
        let session = StubModelSession()
        session.failPreparation = true
        let chat = LocalChatModel(modelSession: session)
        chat.select(.apple)
        let failed = await chat.send("İlk soru")
        XCTAssertNil(failed)
        XCTAssertFalse(chat.isBusy)
        XCTAssertFalse(chat.isLoadingModel)
        XCTAssertNotNil(chat.errorMessage)
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.status, .failed)
        session.failPreparation = false
        let retry = await chat.send("Tekrar")
        XCTAssertEqual(retry?.text, "Merhaba")
        XCTAssertNil(chat.errorMessage)
    }

    func testContextAnswerResetsConversationAndPreservesChatMessages() async throws {
        let session = StubModelSession()
        let chat = LocalChatModel(modelSession: session)
        chat.select(.apple)
        let resetsBefore = session.resets
        let result = try await chat.answerWithContext(question: "Nerede?", context: "Ankara")
        XCTAssertEqual(result.text, "Merhaba")
        XCTAssertTrue(session.prompts.last?.contains("Ankara") == true)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(session.resets, resetsBefore + 1)
        XCTAssertFalse(chat.isBusy)
    }

    func testCancellationClearsBusyStateAndAllowsNextRequest() async {
        let session = StubModelSession()
        session.waitForCancellation = true
        let chat = LocalChatModel(modelSession: session)
        chat.select(.apple)
        let started = expectation(description: "generation started")
        session.onStart = { started.fulfill() }
        let task = Task { await chat.send("İptal") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertFalse(chat.isBusy)
        XCTAssertFalse(chat.isGenerating)
        XCTAssertEqual(chat.messages.last?.text, "Kısmi yanıt")
        XCTAssertEqual(chat.messages.last?.status, .interrupted)
        XCTAssertNil(chat.errorMessage)
        session.waitForCancellation = false
        session.onStart = nil
        let next = await chat.send("Yeni soru")
        XCTAssertEqual(next?.text, "Merhaba")
    }

    func testRegenerationReplacesReplyWithoutDuplicatingQuestion() async {
        let session = StubModelSession()
        let chat = LocalChatModel(modelSession: session)
        chat.select(.apple)
        _ = await chat.send("Soru")
        _ = await chat.regenerate()
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.map(\.text), ["Soru"])
        XCTAssertEqual(chat.messages.last?.status, .complete)
    }

    func testOldMessageFormatStillDecodes() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"role\":\"assistant\",\"text\":\"Eski yanıt\"}".utf8)
        let message = try JSONDecoder().decode(LocalChatMessage.self, from: data)
        XCTAssertEqual(message.status, .complete)
        XCTAssertEqual(message.text, "Eski yanıt")
    }

    func testHistoryRestoresThreadAndMarksUnfinishedReply() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ConversationHistoryStore(directory: directory)
        let thread = history.createThread(modelID: LocalModelChoice.apple.rawValue)
        history.updateThread(id: thread.id, modelID: thread.modelID, messages: [
            LocalChatMessage(role: .user, text: "Soru"),
            LocalChatMessage(role: .assistant, text: "Yarım", status: .generating)
        ], summary: nil, summarizedMessageCount: 0)
        let restored = ConversationHistoryStore(directory: directory)
        XCTAssertEqual(restored.activeThreadID, thread.id)
        XCTAssertEqual(restored.threads.first?.modelID, LocalModelChoice.apple.rawValue)
        XCTAssertEqual(restored.threads.first?.messages.last?.status, .interrupted)
        XCTAssertEqual(restored.threads.first?.messages.last?.text, "Yarım")
    }

    func testModelManagementBlocksGenerationAndAwaitsRelease() async {
        let session = StubModelSession()
        let chat = LocalChatModel(modelSession: session)
        chat.isManagingModels = true
        let blocked = await chat.send("İndirme sırasında soru")
        XCTAssertNil(blocked)
        XCTAssertTrue(session.preparedModels.isEmpty)
        await chat.releaseForModelManagement()
        XCTAssertEqual(session.speechReleases, 1)
        XCTAssertTrue(chat.isBusy)
        chat.isManagingModels = false
        XCTAssertFalse(chat.isBusy)
    }

    func testModelReleaseIsDelegatedToSession() async {
        let session = StubModelSession()
        let chat = LocalChatModel(modelSession: session)
        chat.unloadModel()
        await chat.releaseModelForSpeech()
        XCTAssertEqual(session.unloads, 1)
        XCTAssertEqual(session.speechReleases, 1)
    }
}

@MainActor
private final class StubModelSession: ModelSessionServing {
    var preparedModels: [LocalModelChoice] = []
    var prompts: [String] = []
    var resets = 0
    var unloads = 0
    var speechReleases = 0
    var failPreparation = false
    var waitForCancellation = false
    var onStart: (() -> Void)?

    func prepare(model: LocalModelChoice, startFreshSession: Bool, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        if failPreparation { throw LocalChatError.sessionUnavailable }
        preparedModels.append(model)
        onProgress(1)
    }
    func generate(_ prompt: String, model: LocalModelChoice, onToken: (String) -> Void) async throws -> String {
        prompts.append(prompt)
        if waitForCancellation { onToken("Kısmi yanıt") }
        onStart?()
        if waitForCancellation { try await Task.sleep(for: .seconds(60)) }
        try Task.checkCancellation()
        onToken("Mer")
        onToken("haba")
        return "Merhaba"
    }
    func resetConversation() { resets += 1 }
    func unload() { unloads += 1 }
    func releaseForSpeech() async { speechReleases += 1 }
}
