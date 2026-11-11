import XCTest
@testable import LLM

@MainActor
final class RAGEmbeddingServiceTests: XCTestCase {
    func testIndexUsesInjectedServiceAndPersistsVectors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("note.txt")
        try "Belge içeriği".write(to: source, atomically: true, encoding: .utf8)
        let service = FakeEmbeddingService()
        let model = LocalRAGModel(directory: root, embeddingService: service)
        await model.waitUntilLoaded()
        await model.importDocuments(from: [source])
        await model.indexDocuments(using: LocalChatModel())
        XCTAssertEqual(service.texts, ["Belge içeriği"])
        XCTAssertEqual(model.chunks.first?.embedding, [1, 0])
        XCTAssertFalse(model.isBusy)
        XCTAssertGreaterThan(service.unloads, 0)
        let saved = LocalRAGModel(directory: root)
        await saved.waitUntilLoaded()
        XCTAssertEqual(saved.chunks.first?.embedding, [1, 0])
    }

    func testPreparationFailureAllowsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FakeEmbeddingService()
        service.failPreparation = true
        let model = LocalRAGModel(directory: root, embeddingService: service)
        await model.waitUntilLoaded()
        model.chunks = [RAGChunk(id: UUID(), sourceName: "note", text: "Text")]
        let chat = LocalChatModel()
        await model.indexDocuments(using: chat)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.chunks.first?.embedding)
        service.failPreparation = false
        await model.indexDocuments(using: chat)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.chunks.first?.embedding, [1, 0])
    }
}

@MainActor
private final class FakeEmbeddingService: RAGEmbeddingServing {
    var isSupported = true
    var failPreparation = false
    var texts: [String] = []
    var unloads = 0
    func prepare(choice: RAGEmbeddingChoice, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        if failPreparation { throw Failure.prepare }
        onProgress(1)
    }
    func embed(text: String, isQuery: Bool, choice: RAGEmbeddingChoice) async throws -> [Float] {
        texts.append(text)
        return [1, 0]
    }
    func unload() { unloads += 1 }
    enum Failure: Error { case prepare }
}
