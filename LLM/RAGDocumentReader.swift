import Foundation
import PDFKit
import UIKit

nonisolated struct RAGDocumentPage: Sendable {
    let text: String
    let pageNumber: Int?
}

nonisolated protocol RAGDocumentReading: Sendable {
    func read(from url: URL) throws -> [RAGDocumentPage]
}

/// Reads content only. Security-scoped access and source copies belong to the importer.
nonisolated struct RAGDocumentReader: RAGDocumentReading {
    func read(from url: URL) throws -> [RAGDocumentPage] {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else {
                throw RAGDocumentReadError.cannotReadDocument(url.lastPathComponent)
            }
            return (0..<document.pageCount).compactMap { index in
                guard let text = document.page(at: index)?.string else { return nil }
                return RAGDocumentPage(text: text, pageNumber: index + 1)
            }
        case "txt", "md", "markdown":
            return [RAGDocumentPage(text: try String(contentsOf: url, encoding: .utf8), pageNumber: nil)]
        case "rtf":
            let data = try Data(contentsOf: url)
            let text = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ).string
            return [RAGDocumentPage(text: text, pageNumber: nil)]
        default:
            throw RAGDocumentReadError.unsupportedDocument(url.lastPathComponent)
        }
    }

}

nonisolated enum RAGDocumentReadError: LocalizedError {
    case cannotReadDocument(String)
    case unsupportedDocument(String)
    var errorDescription: String? {
        switch self {
        case .cannotReadDocument(let name): "\(name) PDF dosyası açılamadı."
        case .unsupportedDocument(let name): "\(name) desteklenmiyor. PDF, TXT, Markdown veya RTF seçin."
        }
    }
}
