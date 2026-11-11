import Foundation

nonisolated struct RAGScoredChunk: Identifiable, Sendable {
    var id: UUID { chunk.id }
    let chunk: RAGChunk
    let score: Float
}

/// Exact search over the current snapshot, isolated from the UI and document IO.
actor RAGVectorIndex {
    func rank(query: [Float], chunks: [RAGChunk], limit: Int = 4) throws -> [RAGScoredChunk] {
        guard limit > 0 else { return [] }
        var best: [RAGScoredChunk] = []
        for chunk in chunks {
            try Task.checkCancellation()
            guard let embedding = chunk.embedding,
                  let score = Self.cosineSimilarity(query, embedding) else { continue }
            let item = RAGScoredChunk(chunk: chunk, score: score)
            let position = best.firstIndex { $0.score < score } ?? best.count
            if position < limit {
                best.insert(item, at: position)
                if best.count > limit { best.removeLast() }
            }
        }
        return best
    }

    nonisolated static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0, lhsSquared = 0.0, rhsSquared = 0.0
        for (a, b) in zip(lhs, rhs) {
            guard a.isFinite, b.isFinite else { return nil }
            let a = Double(a), b = Double(b)
            dot += a * b
            lhsSquared += a * a
            rhsSquared += b * b
        }
        guard lhsSquared > 0, rhsSquared > 0 else { return nil }
        return Float(dot / (sqrt(lhsSquared) * sqrt(rhsSquared)))
    }
}
