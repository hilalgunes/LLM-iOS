import Foundation
import Observation
import SwiftUI

struct ChatThread: Codable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelID: String
    var messages: [LocalChatMessage]
    var summary: String?
    var summarizedMessageCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, modelID, messages, summary, summarizedMessageCount
    }

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        modelID: String,
        messages: [LocalChatMessage],
        summary: String?,
        summarizedMessageCount: Int
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelID = modelID
        self.messages = messages
        self.summary = summary
        self.summarizedMessageCount = summarizedMessageCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        modelID = try values.decode(String.self, forKey: .modelID)
        messages = try values.decode([LocalChatMessage].self, forKey: .messages)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        summarizedMessageCount = try values.decodeIfPresent(Int.self, forKey: .summarizedMessageCount) ?? 0
    }
}

enum ConversationKind: String, Codable {
    case chat
    case rag
    case jev

    var title: String {
        switch self {
        case .chat: "Sohbet"
        case .rag: "RAG"
        case .jev: "Jev"
        }
    }
}

struct ConversationRecord: Codable, Identifiable {
    var id: UUID
    var kind: ConversationKind
    var createdAt: Date
    var title: String
    var prompt: String
    var answer: String
    var details: String?
    var modelName: String?
    var totalDurationSeconds: Double?
    var firstResponseSeconds: Double?
}

@Observable
@MainActor
final class ConversationHistoryStore {
    private(set) var records: [ConversationRecord] = []
    private(set) var threads: [ChatThread] = []
    private(set) var activeThreadID: UUID?
    var errorMessage: String?
    private let fileURL: URL
    private let threadsURL: URL

    init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documentsURL.appendingPathComponent("conversation-history.json")
        threadsURL = documentsURL.appendingPathComponent("chat-threads.json")
        do {
            let data = try Data(contentsOf: fileURL)
            records = try JSONDecoder().decode([ConversationRecord].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                errorMessage = "Sohbet geçmişi açılamadı: \(error.localizedDescription)"
            }
        }
        do {
            let data = try Data(contentsOf: threadsURL)
            let saved = try JSONDecoder().decode(ChatThreadsArchive.self, from: data)
            threads = saved.threads.sorted { $0.updatedAt > $1.updatedAt }
            activeThreadID = saved.activeThreadID.flatMap { id in
                threads.contains(where: { $0.id == id }) ? id : nil
            } ?? threads.first?.id
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                errorMessage = "Sohbet oturumları açılamadı: \(error.localizedDescription)"
            }
        }
    }

    func createThread(modelID: String) -> ChatThread {
        let thread = ChatThread(
            id: UUID(),
            title: "Yeni sohbet",
            createdAt: .now,
            updatedAt: .now,
            modelID: modelID,
            messages: [],
            summary: nil,
            summarizedMessageCount: 0
        )
        threads.insert(thread, at: 0)
        activeThreadID = thread.id
        persistThreads()
        return thread
    }

    func updateThread(
        id: UUID,
        modelID: String,
        messages: [LocalChatMessage],
        summary: String?,
        summarizedMessageCount: Int
    ) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].modelID = modelID
        threads[index].messages = messages
        threads[index].summary = summary
        threads[index].summarizedMessageCount = summarizedMessageCount
        threads[index].updatedAt = .now
        if threads[index].title == "Yeni sohbet",
           let firstPrompt = messages.first(where: { $0.role == .user })?.text {
            threads[index].title = String(firstPrompt.prefix(48))
        }
        threads.sort { $0.updatedAt > $1.updatedAt }
        activeThreadID = id
        persistThreads()
    }

    func setActiveThread(_ id: UUID) {
        guard threads.contains(where: { $0.id == id }) else { return }
        activeThreadID = id
        persistThreads()
    }

    func deleteThread(_ thread: ChatThread) {
        threads.removeAll { $0.id == thread.id }
        if activeThreadID == thread.id {
            activeThreadID = threads.first?.id
        }
        persistThreads()
    }

    func renameThread(_ thread: ChatThread, title: String) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        threads[index].title = String(title.prefix(80))
        threads[index].updatedAt = .now
        threads.sort { $0.updatedAt > $1.updatedAt }
        persistThreads()
    }

    func thread(id: UUID) -> ChatThread? {
        threads.first { $0.id == id }
    }

    func add(
        kind: ConversationKind,
        title: String,
        prompt: String,
        answer: String,
        details: String? = nil,
        modelName: String? = nil,
        totalDurationSeconds: Double? = nil,
        firstResponseSeconds: Double? = nil
    ) {
        records.insert(
            ConversationRecord(
                id: UUID(),
                kind: kind,
                createdAt: .now,
                title: title,
                prompt: prompt,
                answer: answer,
                details: details,
                modelName: modelName,
                totalDurationSeconds: totalDurationSeconds,
                firstResponseSeconds: firstResponseSeconds
            ),
            at: 0
        )
        persist()
    }

    func remove(_ record: ConversationRecord) {
        records.removeAll { $0.id == record.id }
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = "Sohbet geçmişi kaydedilemedi: \(error.localizedDescription)"
        }
    }

    private func persistThreads() {
        do {
            let archive = ChatThreadsArchive(activeThreadID: activeThreadID, threads: threads)
            try JSONEncoder().encode(archive).write(to: threadsURL, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = "Sohbet oturumları kaydedilemedi: \(error.localizedDescription)"
        }
    }
}

private struct ChatThreadsArchive: Codable {
    var activeThreadID: UUID?
    var threads: [ChatThread]
}

struct ChatThreadListView: View {
    @Bindable var history: ConversationHistoryStore
    let onSelect: (ChatThread) -> Void
    let onNew: () -> Void
    let onDelete: (ChatThread) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var threadToRename: ChatThread?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if history.threads.isEmpty {
                    ContentUnavailableView(
                        "Henüz sohbet yok",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Yeni sohbet başlatarak konuşmalarını ayrı ayrı sakla.")
                    )
                } else {
                    List {
                        ForEach(history.threads) { thread in
                            Button {
                                onSelect(thread)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(thread.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        if thread.id == history.activeThreadID {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.indigo)
                                        }
                                    }
                                    Text(thread.messages.last?.text ?? "Henüz mesaj yok")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text("\(thread.modelID) · \(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                    Label("Devam et", systemImage: "arrow.uturn.forward")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.indigo)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button {
                                    threadToRename = thread
                                    renameText = thread.title
                                } label: {
                                    Label("Yeniden adlandır", systemImage: "pencil")
                                }
                                .tint(.indigo)

                                Button(role: .destructive) {
                                    onDelete(thread)
                                } label: {
                                    Label("Sil", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sohbetler")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Bitti") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onNew()
                        dismiss()
                    } label: {
                        Label("Yeni", systemImage: "plus")
                    }
                }
            }
            .alert("Sohbeti yeniden adlandır", isPresented: Binding(
                get: { threadToRename != nil },
                set: { if !$0 { threadToRename = nil } }
            )) {
                TextField("Sohbet adı", text: $renameText)
                Button("Kaydet") {
                    if let threadToRename {
                        history.renameThread(threadToRename, title: renameText)
                    }
                    threadToRename = nil
                }
                Button("İptal", role: .cancel) {
                    threadToRename = nil
                }
            }
        }
    }
}

struct HistoryListView: View {
    @Bindable var history: ConversationHistoryStore
    @State private var selectedRecord: ConversationRecord?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if history.records.isEmpty {
                    ContentUnavailableView(
                        "Henüz geçmiş yok",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Sohbetlerin ve Jev değerlendirmelerin burada görünür.")
                    )
                } else {
                    List {
                        ForEach(history.records) { record in
                            Button {
                                selectedRecord = record
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(record.kind.title.uppercased())
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.indigo)
                                        Spacer()
                                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(record.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(record.prompt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 4)
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
            }
            .navigationTitle("Sohbet geçmişi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Bitti") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedRecord) { record in
                HistoryDetailView(record: record)
            }
            .alert(
                "Geçmiş kaydedilemedi",
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
    }
}

private struct HistoryDetailView: View {
    let record: ConversationRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(record.createdAt.formatted(date: .long, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    detailSection("Soru", text: record.prompt)
                    detailSection("Yanıt", text: record.answer)
                    if let details = record.details, !details.isEmpty {
                        detailSection("Ayrıntılar", text: details)
                    }
                }
                .padding(20)
            }
            .navigationTitle(record.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
    }

    private func detailSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
}
