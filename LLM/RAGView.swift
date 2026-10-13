import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct RAGView: View {
    @Bindable var chat: LocalChatModel
    @Bindable var rag: LocalRAGModel
    @Bindable var history: ConversationHistoryStore
    @State private var isShowingImporter = false
    @State private var isShowingHistory = false
    @State private var question = ""
    @State private var selectedSource: RAGChunk?
    @State private var comparisonFirst = RAGEmbeddingChoice.multilingualE5
    @State private var comparisonSecond = RAGEmbeddingChoice.embeddingGemma2

    private var allowedDocumentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .rtf]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        return types
    }

    private var canAsk: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && rag.indexedChunkCount > 0
            && !rag.isBusy
            && !chat.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modelCard
                    documentsCard
                    questionCard
                    comparisonCard

                    if let status = rag.statusMessage {
                        statusCard(status)
                    }

                    if !rag.embeddingComparison.isEmpty {
                        comparisonResultsCard
                    }

                    if !rag.answer.isEmpty {
                        answerCard
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: allowedDocumentTypes,
            allowsMultipleSelection: true,
            onCompletion: handleImportedFiles
        )
        .sheet(isPresented: $isShowingHistory) {
            HistoryListView(history: history)
        }
        .sheet(item: $selectedSource) { source in
            RAGSourceDetailView(source: source, documentURL: rag.sourceURL(for: source))
        }
        .alert(
            "RAG işlemi başarısız",
            isPresented: Binding(
                get: { rag.errorMessage != nil },
                set: { if !$0 { rag.errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) {
                rag.errorMessage = nil
            }
        } message: {
            if let errorMessage = rag.errorMessage {
                Text(errorMessage)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(
                    LinearGradient(
                        colors: [.teal, .indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Belgelere sor · RAG")
                    .font(.headline)
                Text("Belgeler cihazında indekslenir")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isShowingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 38, height: 38)
                    .background(.indigo.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Sohbet geçmişi")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Modeller", systemImage: "cpu")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Yanıt modeli")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(LocalModelChoice.allCases) { model in
                        Button {
                            chat.select(model)
                        } label: {
                            if chat.selectedModel == model {
                                Label(model.title, systemImage: "checkmark")
                            } else {
                                Text(model.title)
                            }
                        }
                    }
                } label: {
                    selectionLabel(chat.selectedModel.title)
                }
                .disabled(rag.isBusy || chat.isBusy)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Embedding modeli")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(RAGEmbeddingChoice.allCases) { choice in
                        Button {
                            rag.selectEmbedding(choice)
                        } label: {
                            if rag.selectedEmbedding == choice {
                                Label(choice.title, systemImage: "checkmark")
                            } else {
                                Text(choice.title)
                            }
                        }
                    }
                } label: {
                    selectionLabel(rag.selectedEmbedding.title)
                }
                .disabled(rag.isBusy)
            }
            Text("Embedding modeli belgelerle soruları eşleştirir. İlk kullanımda seçilen modeller indirilir.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var documentsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Belgeler", systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                Button {
                    isShowingImporter = true
                } label: {
                    Label("Ekle", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(rag.isBusy)
            }

            if rag.documentNames.isEmpty {
                Text("PDF, TXT, Markdown veya RTF dosyası ekleyin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(rag.documentNames, id: \.self) { name in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.teal)
                        Text(name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            rag.removeDocument(named: name)
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline)
                        }
                        .disabled(rag.isBusy)
                        .accessibilityLabel("\(name) belgesini sil")
                    }
                    .padding(.vertical, 3)
                }
            }

            if !rag.chunks.isEmpty {
                Text("\(rag.indexedChunkCount) / \(rag.chunks.count) parça indeksli")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await rag.indexDocuments(using: chat) }
                } label: {
                    HStack {
                        if rag.isBusy && rag.hasUnembeddedChunks {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "square.stack.3d.up.fill")
                        }
                        Text(rag.hasUnembeddedChunks ? "Belgeleri indeksle" : "İndeks güncel")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(rag.hasUnembeddedChunks ? Color.teal : Color.gray, in: Capsule())
                }
                .disabled(!rag.hasUnembeddedChunks || rag.isBusy || chat.isBusy)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Belgelere soru sor", systemImage: "text.bubble")
                .font(.headline)

            TextField("Örneğin: Belgede hangi tarihlerden bahsediliyor?", text: $question, axis: .vertical)
                .lineLimit(2...5)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

            Button(action: askQuestion) {
                HStack {
                    if rag.isBusy && !rag.hasUnembeddedChunks {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                    }
                    Text("Soruyu yanıtla")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(canAsk ? Color.indigo : Color.gray, in: Capsule())
            }
            .disabled(!canAsk)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Yanıt", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.indigo)

            Text(rag.answer)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !rag.sources.isEmpty {
                Divider()
                Text("Kullanılan kaynaklar")
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(rag.sources.enumerated()), id: \.element.id) { index, source in
                    Button {
                        selectedSource = source
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("[\(index + 1)] \(source.sourceName)")
                                if let page = source.pageNumber {
                                    Text("· sayfa \(page)")
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.teal)
                            Text(source.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var comparisonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Embedding modellerini karşılaştır", systemImage: "arrow.left.arrow.right")
                .font(.headline)

            Text("Aynı soru ve belgeler için her modelin bulduğu en yakın 3 parçayı yan yana inceleyin.")
                .font(.caption)
                .foregroundStyle(.secondary)

            comparisonPicker(title: "1. model", selection: $comparisonFirst)
            comparisonPicker(title: "2. model", selection: $comparisonSecond)

            Button {
                Task {
                    await rag.compareEmbeddings(
                        for: question,
                        choices: [comparisonFirst, comparisonSecond],
                        using: chat
                    )
                }
            } label: {
                HStack {
                    if rag.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    Text("Karşılaştırmayı çalıştır")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(canCompare ? Color.teal : Color.gray, in: Capsule())
            }
            .disabled(!canCompare)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var comparisonResultsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Karşılaştırma sonuçları", systemImage: "chart.bar.xaxis")
                .font(.headline)

            Text("Sıralama ve benzerlik puanları modeller arasında doğrudan kalite ölçüsü değildir. Üstte çıkan parçaların soruyu gerçekten yanıtlayıp yanıtlamadığını karşılaştırın.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(rag.embeddingComparison) { comparison in
                VStack(alignment: .leading, spacing: 10) {
                    Text(comparison.choice.title)
                        .font(.subheadline.weight(.semibold))

                    ForEach(Array(comparison.results.enumerated()), id: \.element.id) { index, item in
                        Button {
                            selectedSource = item.chunk
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("#\(index + 1) · \(item.chunk.sourceName)")
                                    Spacer()
                                    Text(String(format: "%.5f", Double(item.score)))
                                        .monospacedDigit()
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.teal)

                                Text(item.chunk.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if comparison.id != rag.embeddingComparison.last?.id {
                    Divider()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var canCompare: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rag.chunks.isEmpty
            && comparisonFirst != comparisonSecond
            && !rag.isBusy
            && !chat.isBusy
    }

    private func comparisonPicker(
        title: String,
        selection: Binding<RAGEmbeddingChoice>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(RAGEmbeddingChoice.allCases) { choice in
                    Button {
                        selection.wrappedValue = choice
                    } label: {
                        if selection.wrappedValue == choice {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(choice.title)
                        }
                    }
                }
            } label: {
                selectionLabel(selection.wrappedValue.title)
            }
            .disabled(rag.isBusy || chat.isBusy)
        }
    }

    private func statusCard(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.teal)
                Text(status)
                    .font(.subheadline)
                Spacer()
                if rag.progress > 0 {
                    Text("\(Int(rag.progress * 100))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
            if rag.progress > 0 {
                ProgressView(value: rag.progress)
                    .tint(.teal)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func selectionLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private func handleImportedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task { await rag.importDocuments(from: urls) }
        case .failure(let error):
            rag.errorMessage = "Dosya seçilemedi: \(error.localizedDescription)"
        }
    }

    private func askQuestion() {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        Task { await rag.ask(prompt, using: chat, history: history) }
    }
}
