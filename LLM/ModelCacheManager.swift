import Foundation
import HuggingFace
import Observation

struct ManagedModel: Identifiable {
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
    private let cache = HubCache.default

    var freeBytes: Int64 {
        (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

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

    init() {
        models = LocalModelChoice.allCases.filter { $0 != .apple }.map {
            ManagedModel(id: $0.repositoryID, title: $0.title, category: "Sohbet")
        } + RAGEmbeddingChoice.allCases.map {
            ManagedModel(id: $0.repositoryID, title: $0.title, category: "Embedding")
        }
        refresh()
    }

    func refresh() {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            sizes = try Dictionary(uniqueKeysWithValues: models.map { model in
                let blobs = cache.cacheDirectory
                    .appendingPathComponent(model.cacheFolderName, isDirectory: true)
                    .appendingPathComponent("blobs", isDirectory: true)
                return (model.id, try Self.directorySize(blobs))
            })
            readyModels = Set(models.filter { model in
                let repository = cache.cacheDirectory.appendingPathComponent(model.cacheFolderName)
                return Self.hasRequiredFiles(in: repository)
            }.map(\.id))
            errorMessage = nil
        } catch {
            errorMessage = "Model önbelleği okunamadı: \(error.localizedDescription)"
        }
    }

    func delete(_ model: ManagedModel, chat: LocalChatModel, rag: LocalRAGModel) {
        guard begin(model, chat: chat, rag: rag) else { return }
        isDeleting = true
        operation = Task {
            defer { finish(chat: chat, rag: rag) }
            do {
                // Await native eviction before touching cached files.
                await chat.releaseForModelManagement()
                rag.unloadEmbedder()
                let repository = cache.cacheDirectory.appendingPathComponent(
                    model.cacheFolderName,
                    isDirectory: true
                )
                if FileManager.default.fileExists(atPath: repository.path) {
                    try FileManager.default.removeItem(at: repository)
                }

                let metadata = cache.cacheDirectory
                    .appendingPathComponent(".metadata", isDirectory: true)
                    .appendingPathComponent(model.cacheFolderName, isDirectory: true)
                if FileManager.default.fileExists(atPath: metadata.path) {
                    try FileManager.default.removeItem(at: metadata)
                }
                let locks = cache.cacheDirectory
                    .appendingPathComponent(".locks", isDirectory: true)
                    .appendingPathComponent(model.cacheFolderName, isDirectory: true)
                if FileManager.default.fileExists(atPath: locks.path) {
                    try FileManager.default.removeItem(at: locks)
                }
                notices[model.id] = nil
            } catch {
                errorMessage = "\(model.title) silinemedi: \(error.localizedDescription)"
            }
        }
    }

    // Disk usage alone does not prove that a snapshot is complete.
    static func hasRequiredFiles(in repository: URL) -> Bool {
        guard let revision = try? String(contentsOf: repository.appendingPathComponent("refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !revision.isEmpty, !revision.contains("/"), revision != ".." else { return false }
        let snapshot = repository.appendingPathComponent("snapshots").appendingPathComponent(revision)
        func exists(_ name: String) -> Bool {
            guard !name.contains(".."), !name.hasPrefix("/") else { return false }
            let attributes = try? FileManager.default.attributesOfItem(atPath: snapshot.appendingPathComponent(name).resolvingSymlinksInPath().path)
            return attributes?[.type] as? FileAttributeType == .typeRegular && ((attributes?[.size] as? NSNumber)?.int64Value ?? 0) > 0
        }
        guard exists("config.json"), exists("tokenizer.json") else { return false }
        let index = snapshot.appendingPathComponent("model.safetensors.index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            guard let data = try? Data(contentsOf: index),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weights = json["weight_map"] as? [String: String], !weights.isEmpty else { return false }
            return Set(weights.values).allSatisfy(exists)
        }
        return exists("model.safetensors")
    }

    private static func directorySize(_ directory: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ModelCacheError.cannotEnumerate(directory.lastPathComponent)
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

private enum ModelCacheError: LocalizedError {
    case cannotEnumerate(String)

    var errorDescription: String? {
        switch self {
        case .cannotEnumerate(let directory):
            "“\(directory)” model dosyaları taranamadı."
        }
    }
}

extension Int64 {
    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
