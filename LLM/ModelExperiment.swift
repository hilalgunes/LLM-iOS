import Foundation
import Observation

nonisolated struct ExperimentDefinition: Codable, Equatable, Sendable {
    var modelId: String
    var runtime: String
    var prompt: String
    var maxTokens: Int
    var mode: String
    var modelRevision: String?
    var temperature: Double?
    var chunkSize: Int?
    var chunkOverlap: Int?
    var topK: Int?
}
nonisolated struct ExperimentMetrics: Codable, Sendable {
    var preparationMs: Double
    var generationMs: Double
    var firstTokenMs: Double?
    var totalMs: Double
}
nonisolated struct ExperimentRecord: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID().uuidString
    var createdAtEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
    var platform = "ios"
    var definition: ExperimentDefinition
    var metrics: ExperimentMetrics
    var status: String
    var output: String
    var error: String?
}

actor ExperimentStore {
    private let file: URL
    init(directory: URL) { file = directory.appendingPathComponent("experiments-v1.json") }
    func load() throws -> [ExperimentRecord] {
        do {
            let records = try JSONDecoder().decode([ExperimentRecord].self, from: Data(contentsOf: file))
            guard records.allSatisfy({ $0.schemaVersion == 1 }) else { throw ExperimentError.unsupportedVersion }
            return records
        } catch CocoaError.fileReadNoSuchFile { return [] }
    }
    func append(_ record: ExperimentRecord) throws -> [ExperimentRecord] {
        let records = [record] + (try load())
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: file, options: .atomic)
        return records
    }
}

@MainActor
@Observable
final class ModelExperimentController {
    var model = LocalModelChoice.qwen
    var prompt = "Yerel dil modellerinin kullanımını üç maddede anlat."
    var mode = "cold"
    private(set) var records: [ExperimentRecord] = []
    private(set) var isLoading = true
    private(set) var isRunning = false
    private(set) var output = ""
    var errorMessage: String?
    private let service: any ModelSessionServing
    private let store: ExperimentStore
    private let clock: () -> Double
    private var loading: Task<Void, Never>?

    init(service: (any ModelSessionServing)? = nil, directory: URL? = nil,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.service = service ?? LocalModelSessionService()
        self.clock = clock
        store = ExperimentStore(directory: directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
        loading = Task { [weak self, store] in
            do { let records = try await store.load(); self?.records = records; self?.isLoading = false }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }
    func waitUntilLoaded() async { await loading?.value }

    func restore(_ record: ExperimentRecord) {
        guard !isRunning else { return }
        guard let selected = LocalModelChoice.allCases.first(where: { $0.id == record.definition.modelId }),
              selected != .apple, record.definition.maxTokens == selected.responseTokenLimit,
              record.definition.temperature == 0.6, record.definition.runtime == "MLX" else {
            errorMessage = "Bu deneyin modeli veya üretim ayarları bu sürümde desteklenmiyor."
            return
        }
        model = selected
        prompt = record.definition.prompt
        mode = record.definition.mode
        errorMessage = nil
    }

    func run() async {
        guard !isRunning, !isLoading else { return }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["cold", "warm"].contains(mode), model != .apple else {
            errorMessage = "Bir MLX modeli, soru ve geçerli ölçüm modu seçin."
            return
        }
        let selected = model
        let definition = ExperimentDefinition(modelId: selected.id, runtime: "MLX", prompt: prompt,
            maxTokens: selected.responseTokenLimit, mode: mode, temperature: 0.6)
        isRunning = true
        output = ""
        errorMessage = nil
        defer { isRunning = false }
        var start = clock()
        var prepared: Double?
        var first: Double?
        var status = "complete"
        var failure: String?
        do {
            await service.releaseForSpeech()
            if definition.mode == "warm" {
                try await service.prepare(model: selected, startFreshSession: true) { _ in }
                _ = try await service.generate(definition.prompt, model: selected) { _ in }
            }
            try Task.checkCancellation()
            start = clock()
            try await service.prepare(model: selected, startFreshSession: true) { _ in }
            prepared = clock()
            output = try await service.generate(definition.prompt, model: selected) { delta in
                if first == nil && !delta.isEmpty { first = (clock() - (prepared ?? start)) * 1000 }
                output += delta
            }
            try Task.checkCancellation()
        } catch {
            status = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
            if status == "failed" { failure = error.localizedDescription }
        }
        let end = clock()
        await service.releaseForSpeech()
        let record = ExperimentRecord(definition: definition,
            metrics: ExperimentMetrics(preparationMs: ((prepared ?? end) - start) * 1000,
                generationMs: prepared.map { (end - $0) * 1000 } ?? 0, firstTokenMs: first, totalMs: (end - start) * 1000),
            status: status, output: output, error: failure)
        do { records = try await store.append(record); errorMessage = failure }
        catch { errorMessage = "Deney kaydedilemedi: \(error.localizedDescription)" }
    }
}

nonisolated private enum ExperimentError: LocalizedError {
    case unsupportedVersion
    var errorDescription: String? { "Desteklenmeyen deney kayıt sürümü." }
}
