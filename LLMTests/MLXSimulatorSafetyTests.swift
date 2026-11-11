import XCTest
@testable import LLM

#if targetEnvironment(simulator)
@MainActor
final class MLXSimulatorSafetyTests: XCTestCase {
    func testUnloadedEmbedderCanBeReleasedRepeatedlyWithoutInitializingMetal() async {
        let rag = LocalRAGModel()
        await rag.waitUntilLoaded()
        for _ in 0..<20 { rag.unloadEmbedder() }
        MLXRuntimeSupport.clearCache()
        XCTAssertFalse(rag.isBusy)
        XCTAssertFalse(MLXRuntimeSupport.isSupported)
    }

    func testIdleSessionReleaseForSpeechAndModelManagementIsSafe() async {
        let service = LocalModelSessionService()
        service.unload()
        await service.releaseForSpeech()
        await service.releaseForSpeech()
        let chat = LocalChatModel(modelSession: service)
        await chat.releaseForModelManagement()
        XCTAssertFalse(chat.isBusy)
    }

    func testDirectMLXPreparationIsRejectedBeforeDownload() async {
        let service = LocalModelSessionService()
        var reportedProgress = false
        do {
            try await service.prepare(model: .qwen, startFreshSession: true) { _ in reportedProgress = true }
            XCTFail("MLX must not load on the simulator")
        } catch {
            XCTAssertEqual(error.localizedDescription, LocalChatError.simulatorNotSupported.localizedDescription)
        }
        XCTAssertFalse(reportedProgress)
        await service.releaseForSpeech()
    }

    func testRAGRequestsReportUnsupportedRuntimeWithoutChangingIndex() async throws {
        let rag = LocalRAGModel()
        await rag.waitUntilLoaded()
        let originalIDs = rag.chunks.map(\.id)
        let chat = LocalChatModel()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ConversationHistoryStore(directory: directory)
        let expected = LocalChatError.simulatorNotSupported.localizedDescription
        await rag.indexDocuments(using: chat)
        XCTAssertEqual(rag.errorMessage, expected)
        rag.errorMessage = nil
        await rag.ask("Soru", using: chat, history: history)
        XCTAssertEqual(rag.errorMessage, expected)
        rag.errorMessage = nil
        await rag.compareEmbeddings(for: "Soru", choices: [.multilingualE5, .qwen3], using: chat)
        XCTAssertEqual(rag.errorMessage, expected)
        XCTAssertEqual(rag.chunks.map(\.id), originalIDs)
        XCTAssertFalse(rag.isBusy)
    }
}
#endif
