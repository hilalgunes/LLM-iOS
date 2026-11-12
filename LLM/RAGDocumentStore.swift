import Foundation

nonisolated struct RAGChunk: Codable, Identifiable, Sendable {
    var id: UUID
    var sourceName: String
    var text: String
    var embedding: [Float]?
    var sourceStorageName: String?
    var pageNumber: Int?

    // Legacy indexes have no stored original; preserve their name-based grouping.
    var documentID: String { sourceStorageName.map { "file:" + $0 } ?? "legacy:" + sourceName }
}

nonisolated struct RAGDocumentSummary: Identifiable, Sendable {
    let id: String
    let name: String
    let chunkCount: Int
}

/// Serializes document and index IO away from the UI actor.
actor RAGDocumentStore {
    nonisolated let sourceDirectory: URL
    private let indexURL: URL
    private let reader: any RAGDocumentReading

    init(directory: URL, reader: any RAGDocumentReading = RAGDocumentReader()) {
        sourceDirectory = directory.appendingPathComponent("rag-source-files", isDirectory: true)
        indexURL = directory.appendingPathComponent("rag-index.json")
        self.reader = reader
    }

    func load() throws -> [RAGChunk] {
        do {
            let chunks = try JSONDecoder().decode([RAGChunk].self, from: Data(contentsOf: indexURL))
            cleanupOrphanedSources(referencedBy: chunks)
            return chunks
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }

    private func cleanupOrphanedSources(referencedBy chunks: [RAGChunk]) {
        let referenced = Set(chunks.compactMap(\.sourceStorageName))
        guard let files = try? FileManager.default.contentsOfDirectory(at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    func save(_ chunks: [RAGChunk]) throws {
        let data = try JSONEncoder().encode(chunks)
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: indexURL, options: .atomic)
    }

    func importing(_ urls: [URL], into existing: [RAGChunk]) throws -> [RAGChunk] {
        var copies: [URL] = []
        do {
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            var added: [RAGChunk] = []
            for url in urls {
                try Task.checkCancellation()
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                let storedName = "\(UUID().uuidString).\(url.pathExtension)"
                let storedURL = sourceDirectory.appendingPathComponent(storedName)
                let pages = try reader.read(from: url)
                var pieces: [RAGChunk] = []
                for page in pages {
                    try Task.checkCancellation()
                    pieces += try RAGTextChunker.split(page.text).map {
                        RAGChunk(id: UUID(), sourceName: url.lastPathComponent, text: $0,
                                 embedding: nil, sourceStorageName: storedName, pageNumber: page.pageNumber)
                    }
                }
                guard !pieces.isEmpty else { throw DocumentStoreError.emptyDocument(url.lastPathComponent) }
                copies.append(storedURL)
                try FileManager.default.copyItem(at: url, to: storedURL)
                added += pieces
            }
            try Task.checkCancellation()
            guard !added.isEmpty else { return existing }
            let result = existing + added
            try save(result)
            return result
        } catch {
            for url in copies { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Commit the index before removing originals so a failed write leaves usable documents.
    func removing(documentID: String, from chunks: [RAGChunk]) throws -> [RAGChunk] {
        let remaining = chunks.filter { $0.documentID != documentID }
        try save(remaining)
        let retained = Set(remaining.compactMap(\.sourceStorageName))
        let removed = Set(chunks.filter { $0.documentID == documentID }.compactMap(\.sourceStorageName))
        for storedName in removed.subtracting(retained) where URL(fileURLWithPath: storedName).lastPathComponent == storedName {
            // A leftover original is harmless; a committed index must still reach the UI.
            try? FileManager.default.removeItem(at: sourceDirectory.appendingPathComponent(storedName))
        }
        cleanupOrphanedSources(referencedBy: remaining)
        return remaining
    }
}

nonisolated private enum DocumentStoreError: LocalizedError {
    case emptyDocument(String)
    var errorDescription: String? {
        switch self { case .emptyDocument(let name): "\(name) dosyasından metin çıkarılamadı." }
    }
}
