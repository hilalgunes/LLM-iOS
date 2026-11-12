import Foundation

nonisolated struct ModelCacheInventory: Sendable {
    let sizes: [String: Int64]
    let ready: Set<String>
    let freeBytes: Int64
}

actor ModelCacheStore {
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func inventory(models: [ManagedModel]) throws -> ModelCacheInventory {
        var sizes: [String: Int64] = [:]
        var ready: Set<String> = []
        for model in models {
            try Task.checkCancellation()
            let repository = directory.appendingPathComponent(model.cacheFolderName)
            sizes[model.id] = try Self.directorySize(repository.appendingPathComponent("blobs"))
            if Self.hasRequiredFiles(in: repository) { ready.insert(model.id) }
        }
        let free = (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return ModelCacheInventory(sizes: sizes, ready: ready, freeBytes: free)
    }

    func delete(_ model: ManagedModel) throws {
        for prefix in ["", ".metadata", ".locks"] {
            let parent = prefix.isEmpty ? directory : directory.appendingPathComponent(prefix)
            let url = parent.appendingPathComponent(model.cacheFolderName)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    // Disk usage alone does not prove that a snapshot is complete.
    nonisolated static func hasRequiredFiles(in repository: URL) -> Bool {
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

    nonisolated private static func directorySize(_ directory: URL) throws -> Int64 {
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
nonisolated private enum ModelCacheError: LocalizedError {
    case cannotEnumerate(String)

    var errorDescription: String? {
        switch self {
        case .cannotEnumerate(let directory):
            "“\(directory)” model dosyaları taranamadı."
        }
    }
}

