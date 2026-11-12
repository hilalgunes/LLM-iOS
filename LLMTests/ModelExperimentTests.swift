import XCTest
@testable import LLM

@MainActor
final class ModelExperimentTests: XCTestCase {
    func testWarmupIsExcludedAndReplayRestoresSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ExperimentSessionStub()
        var time = 0.0
        let controller = ModelExperimentController(service: service, directory: root, clock: { time += 0.001; return time })
        await controller.waitUntilLoaded()
        controller.mode = "warm"
        controller.prompt = "Soru"
        await controller.run()
        let record = try XCTUnwrap(controller.records.first)
        XCTAssertEqual(service.generations, 2)
        XCTAssertEqual(service.freshSessions, [true, true])
        XCTAssertEqual(record.output, "Yanıt 2")
        XCTAssertEqual(record.status, "complete")
        XCTAssertEqual(record.metrics.totalMs, record.metrics.preparationMs + record.metrics.generationMs, accuracy: 0.0001)
        controller.prompt = "Başka"
        controller.restore(record)
        XCTAssertEqual(controller.prompt, "Soru")
        XCTAssertEqual(controller.mode, "warm")
        let store = ExperimentStore(directory: root)
        let saved = try await store.load()
        XCTAssertEqual(saved.first?.id, record.id)
        XCTAssertEqual(saved.first?.definition, record.definition)
    }

    func testCancellationSavesPartialAnswerAndReleasesService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ExperimentSessionStub()
        service.cancelGeneration = true
        let controller = ModelExperimentController(service: service, directory: root)
        await controller.waitUntilLoaded()
        await controller.run()
        XCTAssertEqual(controller.records.first?.status, "cancelled")
        XCTAssertEqual(controller.records.first?.output, "Yanıt 1")
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(service.releases, 2)
    }

    func testCorruptHistoryIsNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("experiments-v1.json")
        try Data("broken".utf8).write(to: file)
        let controller = ModelExperimentController(service: ExperimentSessionStub(), directory: root)
        await controller.waitUntilLoaded()
        await controller.run()
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(controller.records.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }
}

@MainActor
private final class ExperimentSessionStub: ModelSessionServing {
    var freshSessions: [Bool] = []
    var generations = 0
    var releases = 0
    var cancelGeneration = false
    func prepare(model: LocalModelChoice, startFreshSession: Bool, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        freshSessions.append(startFreshSession)
    }
    func generate(_ prompt: String, model: LocalModelChoice, onToken: (String) -> Void) async throws -> String {
        generations += 1
        let text = "Yanıt \(generations)"
        onToken(text)
        if cancelGeneration { throw CancellationError() }
        return text
    }
    func resetConversation() {}
    func unload() {}
    func releaseForSpeech() async { releases += 1 }
}
