import XCTest
@testable import LLM

@MainActor
final class RAGVectorIndexTests: XCTestCase {
    private func chunk(_ text: String, _ vector: [Float]?) -> RAGChunk {
        RAGChunk(id: UUID(), sourceName: text, text: text, embedding: vector)
    }

    func testTopKIsStableAndSkipsInvalidVectors() async throws {
        let chunks = [chunk("negative", [-1, 0]), chunk("first", [1, 0]),
                      chunk("second", [2, 0]), chunk("zero", [0, 0]),
                      chunk("mismatch", [1]), chunk("nan", [.nan, 1]), chunk("missing", nil)]
        let index = RAGVectorIndex()
        let result = try await index.rank(query: [1, 0], chunks: chunks, limit: 2)
        XCTAssertEqual(result.map { $0.chunk.text }, ["first", "second"])
        XCTAssertEqual(result.map(\.score), [1, 1])
        let empty = try await index.rank(query: [0, 0], chunks: chunks)
        XCTAssertTrue(empty.isEmpty)
        let noResults = try await index.rank(query: [1, 0], chunks: chunks, limit: 0)
        XCTAssertTrue(noResults.isEmpty)
    }

    func testCancellationStopsSearch() async throws {
        let index = RAGVectorIndex()
        let chunks = [chunk("one", [1, 0])]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await index.rank(query: [1, 0], chunks: chunks)
        }
        do { _ = try await task.value; XCTFail("Cancelled search should stop") }
        catch is CancellationError {}
    }
}
