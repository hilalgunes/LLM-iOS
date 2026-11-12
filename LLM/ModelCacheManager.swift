import Foundation
import HuggingFace
import Observation

nonisolated struct ManagedModel: Identifiable, Sendable {
    let id: String
    let title: String
    let category: String

    var cacheFolderName: String {
        "models--" + id.replacingOccurrences(of: "/", with: "--")
    }
}

@Observable
@MainActor
final class ModelCacheManager {
    private(set) var models: [ManagedModel] = []
    private(set) var sizes: [String: Int64] = [:]
    private(set) var isRefreshing = false
    var errorMessage: String?

    private(set) var activeModelID: String?
    private(set) var progress: Double = 0
    private(set) var isCancelling = false
    private(set) var isDeleting = false
    private(set) var readyModels: Set<String> = []
    private(set) var notices: [String: String] = [:]
    private var operation: Task<Void, Never>?
    private let store: ModelCacheStore
    private var refreshTask: Task<Void, Never>?
    private var refreshRevision = 0
    private(set) var freeBytes: Int64 = 0

    func download(_ model: ManagedModel, chat: LocalChatModel, rag: LocalRAGModel) {
        guard begin(model, chat: chat, rag: rag) else { return }
        notices[model.id] = nil
        progress = 0
        operation = Task {
            defer { finish(chat: chat, rag: rag) }
            do {
                guard let repo = Repo.ID(rawValue: model.id) else { throw URLError(.badURL) }
                _ = try await HubClient().downloadSnapshot(of: repo,
                    matching: ["*.safetensors", "*.json", "*.jinja"],
                    progressHandler: { [weak self] value in self?.progress = value.fractionCompleted })
                try Task.checkCancellation()
                notices[model.id] = "İndirme tamamlandı"
            } catch is CancellationError {
                notices[model.id] = "İptal edildi · Tekrar indirebilirsin"
            } catch {
                notices[model.id] = Task.isCancelled ? "İptal edildi · Tekrar indirebilirsin" : "İndirme başarısız · Tekrar dene"
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelDownload() {
        guard !isDeleting, activeModelID != nil else { return }
        isCancelling = true
        operation?.cancel()
    }

    private func begin(_ model: ManagedModel, chat: LocalChatModel, rag: LocalRAGModel) -> Bool {
        guard activeModelID == nil, !chat.isBusy, !rag.isBusy else {
            errorMessage = "Devam eden model işlemi tamamlanınca yeniden deneyin."
            return false
        }
        chat.isManagingModels = true
        rag.isManagingModels = true
        activeModelID = model.id
        errorMessage = nil
        return true
    }

    private func finish(chat: LocalChatModel, rag: LocalRAGModel) {
        let failure = errorMessage
        refresh()
        if let failure { errorMessage = failure }
        chat.isManagingModels = false
        rag.isManagingModels = false
        activeModelID = nil
        isCancelling = false
        isDeleting = false
        operation = nil
    }

    init(directory: URL? = nil) {
        store = ModelCacheStore(directory: directory ?? HubCache.default.cacheDirectory)
        models = LocalModelChoice.allCases.filter { $0 != .apple }.map {
            ManagedModel(id: $0.repositoryID, title: $0.title, category: "Sohbet")
        } + RAGEmbeddingChoice.allCases.map {
            ManagedModel(id: $0.repositoryID, title: $0.title, category: "Embedding")
        }
        refresh()
    }

    func refresh() {
        refreshRevision += 1
        let revision = refreshRevision
        refreshTask?.cancel()
        isRefreshing = true
        refreshTask = Task { [weak self, store, models] in
            do {
                let inventory = try await store.inventory(models: models)
                guard let self, self.refreshRevision == revision, !Task.isCancelled else { return }
                self.sizes = inventory.sizes
                self.readyModels = inventory.ready
                self.freeBytes = inventory.freeBytes
                self.isRefreshing = false
            } catch {
                guard let self, self.refreshRevision == revision else { return }
                self.isRefreshing = false
                if !(error is CancellationError) {
                    self.errorMessage = "Model önbelleği okunamadı: \(error.localizedDescription)"
                }
            }
        }
    }

    func waitForRefresh() async { await refreshTask?.value }

    func delete(_ model: ManagedModel, chat: LocalChatModel, rag: LocalRAGModel) {
        guard begin(model, chat: chat, rag: rag) else { return }
        isDeleting = true
        operation = Task {
            defer { finish(chat: chat, rag: rag) }
            do {
                // Await native eviction before touching cached files.
                await chat.releaseForModelManagement()
                rag.unloadEmbedder()
                try await store.delete(model)
                notices[model.id] = nil
            } catch {
                errorMessage = "\(model.title) silinemedi: \(error.localizedDescription)"
            }
        }
    }

    nonisolated static func hasRequiredFiles(in repository: URL) -> Bool {
        ModelCacheStore.hasRequiredFiles(in: repository)
    }
}

extension Int64 {
    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
