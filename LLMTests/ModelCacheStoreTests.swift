import XCTest
@testable import LLM

@MainActor
final class ModelCacheStoreTests: XCTestCase {
    func testInventoryAndDeletionPreserveOtherModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ManagedModel(id: "test/one", title: "One", category: "Test")
        let second = ManagedModel(id: "test/two", title: "Two", category: "Test")
        for model in [first, second] {
            let directory = root.appendingPathComponent(model.cacheFolderName)
            for (name, value) in ["refs/main": "rev", "blobs/weights": "123456", "snapshots/rev/config.json": "{}", "snapshots/rev/tokenizer.json": "{}", "snapshots/rev/model.safetensors": "weights"] {
                let file = directory.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(value.utf8).write(to: file)
            }
        }
        let store = ModelCacheStore(directory: root)
        let before = try await store.inventory(models: [first, second])
        XCTAssertEqual(before.ready, [first.id, second.id])
        XCTAssertEqual(before.sizes[first.id], 6)
        try await store.delete(first)
        let after = try await store.inventory(models: [first, second])
        XCTAssertEqual(after.ready, [second.id])
        XCTAssertEqual(after.sizes[first.id], 0)
        XCTAssertEqual(after.sizes[second.id], 6)
    }

    func testRepeatedRefreshFinishesAndPreservesOperationError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelCacheManager(directory: root)
        manager.errorMessage = "Download failed"
        for _ in 0..<10 { manager.refresh() }
        await manager.waitForRefresh()
        XCTAssertFalse(manager.isRefreshing)
        XCTAssertEqual(manager.errorMessage, "Download failed")
        XCTAssertTrue(manager.readyModels.isEmpty)
        XCTAssertGreaterThan(manager.freeBytes, 0)
    }
}
