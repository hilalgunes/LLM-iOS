import XCTest
@testable import LLM

@MainActor
final class ModelCacheManagerTests: XCTestCase {
    private func repository(_ files: [String: String], check: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, value) in files.merging(["refs/main": "revision\n"], uniquingKeysWith: { _, new in new }) {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }
        try check(root)
    }

    func testPartialBlobsAreNotReady() throws {
        try repository(["blobs/weights.incomplete": "partial"]) {
            XCTAssertFalse(ModelCacheManager.hasRequiredFiles(in: $0))
        }
    }

    func testCompleteSingleFileSnapshotIsRecognized() throws {
        try repository(["snapshots/revision/config.json": "{}", "snapshots/revision/tokenizer.json": "{}", "snapshots/revision/model.safetensors": "weights"]) {
            XCTAssertTrue(ModelCacheManager.hasRequiredFiles(in: $0))
        }
    }

    func testMissingOrEmptyShardIsNotReady() throws {
        let files = ["snapshots/revision/config.json": "{}", "snapshots/revision/tokenizer.json": "{}", "snapshots/revision/model.safetensors.index.json": #"{"weight_map":{"a":"one.safetensors","b":"two.safetensors"}}"#, "snapshots/revision/one.safetensors": "weights"]
        try repository(files) { root in
            XCTAssertFalse(ModelCacheManager.hasRequiredFiles(in: root))
            let second = root.appendingPathComponent("snapshots/revision/two.safetensors")
            try Data().write(to: second)
            XCTAssertFalse(ModelCacheManager.hasRequiredFiles(in: root))
            try Data("weights".utf8).write(to: second)
            XCTAssertTrue(ModelCacheManager.hasRequiredFiles(in: root))
        }
    }
}
