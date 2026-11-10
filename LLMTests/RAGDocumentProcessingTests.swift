import XCTest
import UIKit
@testable import LLM

@MainActor
final class RAGDocumentProcessingTests: XCTestCase {
    func testOverlapAndFinalBoundary() throws {
        XCTAssertEqual(try RAGTextChunker.split("abcdefghij", maximumLength: 4, overlap: 1), ["abcd", "defg", "ghij"])
        XCTAssertEqual(try RAGTextChunker.split("abcdef", maximumLength: 4, overlap: 0), ["abcd", "ef"])
    }

    func testEmptyAndShortText() throws {
        XCTAssertEqual(try RAGTextChunker.split(" \n\t "), [])
        XCTAssertEqual(try RAGTextChunker.split("  Türkçe içerik \n"), ["Türkçe içerik"])
    }

    func testInvalidBudgetsThrowEvenForEmptyText() {
        for (size, overlap) in [(0, 0), (-1, 0), (4, -1), (4, 4), (4, 5)] {
            XCTAssertThrowsError(try RAGTextChunker.split("", maximumLength: size, overlap: overlap))
        }
    }

    func testComposedCharactersAreNotSplit() throws {
        XCTAssertEqual(try RAGTextChunker.split("a👨‍👩‍👧‍👦e\u{301}b", maximumLength: 2, overlap: 0), ["a👨‍👩‍👧‍👦", "e\u{301}b"])
    }

    private func withFile(_ suffix: String, data: Data, check: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        try check(url)
    }

    func testUtf8MarkdownKeepsContentWithoutInventingPageNumber() throws {
        let content = "İstanbul, öğüt ve çığ.\nİkinci satır."
        try withFile("md", data: Data(content.utf8)) { url in
            let pages = try RAGDocumentReader().read(from: url)
            XCTAssertEqual(pages.count, 1)
            XCTAssertEqual(pages.first?.text, content)
            XCTAssertNil(pages.first?.pageNumber)
        }
    }

    func testPdfRetainsPageNumbers() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { context in
            for text in ["Alpha", "Bravo"] {
                context.beginPage()
                (text as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)])
            }
        }
        try withFile("PDF", data: data) { url in
            let pages = try RAGDocumentReader().read(from: url)
            XCTAssertEqual(pages.map(\.pageNumber), [1, 2])
            XCTAssertTrue(pages.first?.text.contains("Alpha") == true, "Extracted pages: \(pages.map(\.text))")
            XCTAssertTrue(pages.last?.text.contains("Bravo") == true, "Extracted pages: \(pages.map(\.text))")
        }
    }

    func testRtfExtractsTextInsteadOfMarkup() throws {
        try withFile("rtf", data: Data(#"{\rtf1\ansi Hello document}"#.utf8)) { url in
            let pages = try RAGDocumentReader().read(from: url)
            XCTAssertTrue(pages.first?.text.contains("Hello document") == true)
            XCTAssertNil(pages.first?.pageNumber)
        }
    }

    func testUnsupportedAndInvalidPdfFail() throws {
        for ext in ["xyz", "pdf"] {
            try withFile(ext, data: Data("not a document".utf8)) { url in
                XCTAssertThrowsError(try RAGDocumentReader().read(from: url))
            }
        }
    }
}
