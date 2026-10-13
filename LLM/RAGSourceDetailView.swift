import PDFKit
import SwiftUI

struct RAGSourceDetailView: View {
    let source: RAGChunk
    let documentURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source.sourceName)
                            .font(.headline)
                        if let pageNumber = source.pageNumber {
                            Label("PDF · sayfa \(pageNumber)", systemImage: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Belgeden eşleşen bölüm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let documentURL, documentURL.pathExtension.lowercased() == "pdf" {
                        PDFSourcePageView(url: documentURL, pageNumber: source.pageNumber ?? 1)
                            .frame(height: 440)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Eşleşen metin")
                            .font(.subheadline.weight(.semibold))
                        Text(source.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(16)
            }
            .navigationTitle("Kaynak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }
}

private struct PDFSourcePageView: UIViewRepresentable {
    let url: URL
    let pageNumber: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        goToSourcePage(in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        goToSourcePage(in: view)
    }

    private func goToSourcePage(in view: PDFView) {
        guard let document = view.document else { return }
        let index = min(max(pageNumber - 1, 0), document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        view.go(to: page)
    }
}
