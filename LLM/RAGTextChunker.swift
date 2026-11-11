import Foundation

/// Pure text splitting. Budgets count Swift Characters, preserving composed characters.
nonisolated enum RAGTextChunker {
    static func split(_ text: String, maximumLength: Int = 850, overlap: Int = 120) throws -> [String] {
        guard maximumLength > 0, overlap >= 0, overlap < maximumLength else {
            throw ChunkingError.invalidConfiguration
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maximumLength, limitedBy: text.endIndex) ?? text.endIndex
            let piece = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            guard end < text.endIndex else { break }
            start = text.index(end, offsetBy: -overlap)
        }
        return result
    }

    enum ChunkingError: Error { case invalidConfiguration }
}
