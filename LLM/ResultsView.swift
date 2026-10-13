import SwiftUI

private enum ResultFilter: String, CaseIterable, Identifiable {
    case all
    case chat
    case rag
    case jev

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Tümü"
        case .chat: "Sohbet"
        case .rag: "RAG"
        case .jev: "Jev"
        }
    }

    func includes(_ record: ConversationRecord) -> Bool {
        self == .all || record.kind.rawValue == rawValue
    }
}

struct ResultsView: View {
    @Bindable var history: ConversationHistoryStore
    @State private var filter: ResultFilter = .all
    @State private var selectedResult: ConversationRecord?

    private var results: [ConversationRecord] {
        history.records
            .filter(filter.includes)
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var measuredResults: [ConversationRecord] {
        results.filter { $0.totalDurationSeconds != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("Sonuç türü", selection: $filter) {
                ForEach(ResultFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if results.isEmpty {
                ContentUnavailableView(
                    "Henüz sonuç yok",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Sohbet, RAG veya Jev ile soru sorunca süre ve yanıt bilgileri burada görünür.")
                )
            } else {
                List {
                    if !measuredResults.isEmpty {
                        Section {
                            summaryCard
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }

                    Section("Sorular ve yanıt süreleri") {
                        ForEach(results) { record in
                            Button {
                                selectedResult = record
                            } label: {
                                resultRow(record)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    history.remove(record)
                                } label: {
                                    Label("Sil", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(item: $selectedResult) { record in
            ResultDetailView(record: record)
        }
        .alert(
            "Sonuç kaydedilemedi",
            isPresented: Binding(
                get: { history.errorMessage != nil },
                set: { if !$0 { history.errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) {
                history.errorMessage = nil
            }
        } message: {
            if let errorMessage = history.errorMessage {
                Text(errorMessage)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(
                    LinearGradient(
                        colors: [.indigo, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Sonuçlar")
                    .font(.headline)
                Text("Soru ve yanıt performansı")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private var summaryCard: some View {
        HStack(spacing: 0) {
            metric(
                title: "Ölçülen yanıt",
                value: "\(measuredResults.count)",
                icon: "checkmark.message"
            )
            Divider()
                .frame(height: 42)
            metric(
                title: "Ort. toplam süre",
                value: average(\.totalDurationSeconds),
                icon: "stopwatch"
            )
            Divider()
                .frame(height: 42)
            metric(
                title: "Ort. ilk yanıt",
                value: average(\.firstResponseSeconds),
                icon: "bolt"
            )
        }
        .padding(.vertical, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .padding(.bottom, 4)
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.indigo)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    private func resultRow(_ record: ConversationRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(record.kind.title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.indigo)
                Spacer()
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(record.prompt)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 14) {
                metricBadge(
                    title: "Toplam",
                    value: record.totalDurationSeconds.map(formatDuration) ?? "Eski kayıt"
                )
                metricBadge(
                    title: "İlk yanıt",
                    value: record.firstResponseSeconds.map(formatDuration) ?? "—"
                )
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            if let modelName = record.modelName {
                Text(modelName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
    }

    private func metricBadge(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .font(.caption2.monospacedDigit())
    }

    private func average(_ keyPath: KeyPath<ConversationRecord, Double?>) -> String {
        let values = measuredResults.compactMap { $0[keyPath: keyPath] }
        guard !values.isEmpty else { return "—" }
        return formatDuration(values.reduce(0, +) / Double(values.count))
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 60 {
            return "\(seconds.formatted(.number.precision(.fractionLength(2)))) sn"
        }
        let minutes = Int(seconds / 60)
        let remainingSeconds = seconds - Double(minutes * 60)
        return "\(minutes) dk \(remainingSeconds.formatted(.number.precision(.fractionLength(0)))) sn"
    }
}

private struct ResultDetailView: View {
    let record: ConversationRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label(record.kind.title, systemImage: icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.indigo)
                        Spacer()
                        Text(record.createdAt.formatted(date: .long, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        timingCard(
                            title: "Toplam yanıt süresi",
                            value: record.totalDurationSeconds.map(formatDuration) ?? "Ölçülmedi"
                        )
                        timingCard(
                            title: "İlk yanıtın başlaması",
                            value: record.firstResponseSeconds.map(formatDuration) ?? "Ölçülmedi"
                        )
                    }

                    if let modelName = record.modelName {
                        Label(modelName, systemImage: "cpu")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    contentSection("Sorulan soru", text: record.prompt)
                    contentSection("Yanıt", text: record.answer)
                    if let details = record.details, !details.isEmpty {
                        contentSection("Ayrıntılar ve kaynaklar", text: details)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Sonuç ayrıntısı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }

    private var icon: String {
        switch record.kind {
        case .chat: "bubble.left.and.bubble.right"
        case .rag: "doc.text.magnifyingglass"
        case .jev: "point.3.connected.trianglepath.dotted"
        }
    }

    private func timingCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: title.hasPrefix("İlk") ? "bolt.fill" : "stopwatch")
                .foregroundStyle(.indigo)
            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func contentSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        return "\(seconds.formatted(.number.precision(.fractionLength(2)))) sn"
    }
}
