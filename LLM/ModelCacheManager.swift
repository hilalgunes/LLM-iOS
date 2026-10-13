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

    private let cache = HubCache.default

    init() {
        models = LocalModelChoice.allCases.map {
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
            errorMessage = nil
        } catch {
            errorMessage = "Model önbelleği okunamadı: \(error.localizedDescription)"
        }
    }

    func delete(_ model: ManagedModel, chat: LocalChatModel, rag: LocalRAGModel) {
        guard !chat.isBusy, !rag.isBusy else {
            errorMessage = "Model kullanılırken önbellek silinemez. İşlem tamamlanınca yeniden deneyin."
            return
        }
        do {
            if chat.selectedModel.repositoryID == model.id {
                chat.unloadModel()
            }
            if rag.selectedEmbedding.repositoryID == model.id {
                rag.unloadEmbedder()
            }
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
            refresh()
        } catch {
            errorMessage = "\(model.title) silinemedi: \(error.localizedDescription)"
        }
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
