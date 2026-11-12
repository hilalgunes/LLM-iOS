import Foundation
import AnyLanguageModel
import MLXFoundationModels
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Calls are serialized by the feature coordinator. Cancellation follows the calling Task.
@MainActor
protocol ModelSessionServing: AnyObject {
    func prepare(model: LocalModelChoice, startFreshSession: Bool, onProgress: @escaping @MainActor (Double) -> Void) async throws
    func generate(_ prompt: String, model: LocalModelChoice, onToken: (String) -> Void) async throws -> String
    func resetConversation()
    func unload()
    func releaseForSpeech() async
}

@MainActor
final class LocalModelSessionService: ModelSessionServing {
    private var loadedModelID: String?
    private var modelContainer: ModelContainer?
    private var session: AnyLanguageModel.LanguageModelSession?
    private var nativeModel: MLXFoundationModels.MLXLanguageModel?
    private var pendingEviction: Task<Void, Never>?
    private var isOperating = false
    private var needsMLXCacheCleanup = false

    func resetConversation() {
        guard !isOperating else { return }
        session = nil
    }

    func unload() {
        guard !isOperating else { return }
        releaseResources()
    }

    private func releaseResources() {
        session = nil
        let previousEviction = pendingEviction
        let modelToEvict = nativeModel
        nativeModel = nil
        pendingEviction = Task {
            await previousEviction?.value
            await modelToEvict?.evict()
        }
        modelContainer = nil
        loadedModelID = nil
    }

    func releaseForSpeech() async {
        guard !isOperating else { return }
        unload()
        await pendingEviction?.value
        if needsMLXCacheCleanup {
            MLXRuntimeSupport.clearCache()
            needsMLXCacheCleanup = false
        }
    }

    func prepare(model selectedModel: LocalModelChoice, startFreshSession: Bool, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        guard !isOperating else { throw LocalChatError.modelBusy }
        isOperating = true
        defer { isOperating = false }
        do {
            try await prepareModel(model: selectedModel, startFreshSession: startFreshSession, onProgress: onProgress)
            try Task.checkCancellation()
        } catch {
            releaseResources()
            throw error
        }
    }

    private func prepareModel(model selectedModel: LocalModelChoice, startFreshSession: Bool, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        await pendingEviction?.value
        try Task.checkCancellation()
        if selectedModel == .apple {
            if modelContainer != nil { releaseResources(); await pendingEviction?.value }
            let model = AnyLanguageModel.SystemLanguageModel.default
            guard model.isAvailable else { throw LocalChatError.systemModelUnavailable }
            if startFreshSession || session == nil {
                session = AnyLanguageModel.LanguageModelSession(
                    model: model,
                    instructions: "Türkçe konuşan, açık ve yardımcı bir asistansın."
                )
            }
            return
        }
        try MLXRuntimeSupport.requireSupported()
        if loadedModelID != selectedModel.id {
            releaseResources()
            await pendingEviction?.value
            onProgress(0)

            needsMLXCacheCleanup = true
            let loadedContainer = try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: selectedModel.configuration,
                progressHandler: { progress in
                    let fractionCompleted = progress.fractionCompleted
                    Task { @MainActor in
                        onProgress(min(max(fractionCompleted, 0), 1))
                    }
                }
            )

            modelContainer = loadedContainer
            loadedModelID = selectedModel.id
        }

        if startFreshSession || session == nil {
            guard let modelContainer else {
                throw LocalChatError.sessionUnavailable
            }
            let model = MLXFoundationModels.MLXLanguageModel(
                configuration: selectedModel.configuration,
                capabilities: [],
                weightsLocation: { id in
                    let cache = HubCache.default
                    guard let repo = Repo.ID(rawValue: id) else { return cache.cacheDirectory }
                    if let commit = cache.resolveRevision(repo: repo, kind: .model, ref: "main"),
                       let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit) {
                        return snapshot
                    }
                    return cache.repoDirectory(repo: repo, kind: .model)
                },
                load: { _, _ in modelContainer }
            )
            nativeModel = model
            session = AnyLanguageModel.LanguageModelSession(
                model: AnyLanguageModel.FoundationLanguageModel(model),
                instructions: "Türkçe konuşan, açık ve yardımcı bir asistansın."
            )
        }
    }

    func generate(
        _ prompt: String,
        model selectedModel: LocalModelChoice,
        onToken: (String) -> Void
    ) async throws -> String {
        guard !isOperating else { throw LocalChatError.modelBusy }
        isOperating = true
        defer { isOperating = false }
        guard let session else {
            throw LocalChatError.sessionUnavailable
        }

        var response = ""
        let options = AnyLanguageModel.GenerationOptions(
            temperature: 0.6,
            maximumResponseTokens: selectedModel.responseTokenLimit
        )
        try Task.checkCancellation()
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            try Task.checkCancellation()
            let updated = snapshot.content
            // Session streams cumulative snapshots; the UI and TTS receive only new text.
            if updated.hasPrefix(response) {
                let delta = String(updated.dropFirst(response.count))
                if !delta.isEmpty { onToken(delta) }
            }
            response = updated
        }
        try Task.checkCancellation()
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalChatError.emptyResponse
        }
        return response
    }
}
