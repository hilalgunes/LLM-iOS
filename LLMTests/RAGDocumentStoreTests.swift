import XCTest
@testable import LLM

@MainActor
final class RAGDocumentStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testImportRunsOffMainAndPersistsSource() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("note.txt")
        try "Belge metni".write(to: source, atomically: true, encoding: .utf8)
        let store = RAGDocumentStore(directory: root, reader: BackgroundReader())
        let chunks = try await store.importing([source], into: [])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.pageNumber, 3)
        let saved = try await store.load()
        XCTAssertEqual(saved.map(\.id), chunks.map(\.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sourceDirectory.appendingPathComponent(try XCTUnwrap(chunks.first?.sourceStorageName)).path))
    }

    func testFailedBatchRollsBackCopiesAndPreservesIndex() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("note.txt")
        try "Eski belge".write(to: source, atomically: true, encoding: .utf8)
        let store = RAGDocumentStore(directory: root)
        let original = try await store.importing([source], into: [])
        do {
            _ = try await store.importing([source, root.appendingPathComponent("missing.txt")], into: original)
            XCTFail("Missing document must fail")
        } catch {}
        let saved = try await store.load()
        XCTAssertEqual(saved.map(\.id), original.map(\.id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.sourceDirectory.path).count, 1)
    }

    func testFailedIndexWriteDoesNotPublishImportedChunks() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LocalRAGModel(directory: root)
        await model.waitUntilLoaded()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("rag-index.json"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("note.txt")
        try "Belge".write(to: source, atomically: true, encoding: .utf8)
        await model.importDocuments(from: [source])
        XCTAssertTrue(model.chunks.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: model.sourceDirectory.path).isEmpty)
    }

    func testSameNamedDocumentsHaveIndependentLifetimes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("note.txt")
        try "Birinci".write(to: source, atomically: true, encoding: .utf8)
        let model = LocalRAGModel(directory: root)
        await model.waitUntilLoaded()
        await model.importDocuments(from: [source])
        try "İkinci".write(to: source, atomically: true, encoding: .utf8)
        await model.importDocuments(from: [source])
        XCTAssertEqual(model.documents.count, 2)
        let first = try XCTUnwrap(model.chunks.first)
        let second = try XCTUnwrap(model.chunks.last)
        XCTAssertNotEqual(first.documentID, second.documentID)
        model.sources = [first, second]
        model.selectedSource = first
        await model.removeDocument(id: first.documentID)
        XCTAssertEqual(model.chunks.map(\.id), [second.id])
        XCTAssertEqual(model.sources.map(\.id), [second.id])
        XCTAssertNil(model.selectedSource)
        XCTAssertNil(model.sourceURL(for: first))
        XCTAssertNotNil(model.sourceURL(for: second))
        let reloaded = LocalRAGModel(directory: root)
        await reloaded.waitUntilLoaded()
        XCTAssertEqual(reloaded.documents.map(\.id), [second.documentID])
    }

    func testOrphanCleanupOnlyAfterValidIndexLoad() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RAGDocumentStore(directory: root)
        try FileManager.default.createDirectory(at: store.sourceDirectory, withIntermediateDirectories: true)
        let orphan = store.sourceDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        let unknown = store.sourceDirectory.appendingPathComponent("keep.txt")
        try Data("orphan".utf8).write(to: orphan)
        try Data("unknown".utf8).write(to: unknown)
        try Data("broken".utf8).write(to: root.appendingPathComponent("rag-index.json"))
        do { _ = try await store.load(); XCTFail("Broken index should fail") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        try await store.save([])
        _ = try await store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    }

    func testSourceLabelIncludesDocumentPartAndPage() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LocalRAGModel(directory: root)
        await model.waitUntilLoaded()
        model.chunks = [RAGChunk(id: UUID(), sourceName: "notes.pdf", text: "First", sourceStorageName: "one.pdf", pageNumber: 2),
                        RAGChunk(id: UUID(), sourceName: "notes.pdf", text: "Second", sourceStorageName: "one.pdf", pageNumber: 3)]
        XCTAssertEqual(model.sourceLabel(for: model.chunks[1]), "notes.pdf · Parça 2 · Sayfa 3")
    }

    func testLegacyIndexLoadsAndRemovalPersists() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = "[{\"id\":\"\(UUID().uuidString)\",\"sourceName\":\"legacy.txt\",\"text\":\"Legacy\"}]"
        try Data(json.utf8).write(to: root.appendingPathComponent("rag-index.json"))
        let model = LocalRAGModel(directory: root)
        XCTAssertTrue(model.isBusy)
        await model.waitUntilLoaded()
        XCTAssertEqual(model.chunks.count, 1)
        await model.removeDocument(id: "legacy:legacy.txt")
        XCTAssertTrue(model.chunks.isEmpty)
        let reloaded = LocalRAGModel(directory: root)
        await reloaded.waitUntilLoaded()
        XCTAssertTrue(reloaded.chunks.isEmpty)
    }
}

nonisolated private struct BackgroundReader: RAGDocumentReading {
    func read(from url: URL) throws -> [RAGDocumentPage] {
        guard !Thread.isMainThread else { throw ReaderError.mainThread }
        return [RAGDocumentPage(text: try String(contentsOf: url, encoding: .utf8), pageNumber: 3)]
    }
    enum ReaderError: Error { case mainThread }
}
