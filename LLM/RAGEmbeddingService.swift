import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

@MainActor
protocol RAGEmbeddingServing {
    var isSupported: Bool { get }
    func prepare(choice: RAGEmbeddingChoice, onProgress: @escaping @MainActor (Double) -> Void) async throws
    func embed(text: String, isQuery: Bool, choice: RAGEmbeddingChoice) async throws -> [Float]
    func unload()
}

@MainActor
final class RAGEmbeddingService: RAGEmbeddingServing {
    var isSupported: Bool { MLXRuntimeSupport.isSupported }
    private var embedder: EmbedderModelContainer?
    private var loadedEmbeddingID: String?
    private var revision = 0

    func unload() {
        revision += 1
        let hadModel = embedder != nil
        embedder = nil
        loadedEmbeddingID = nil
        if hadModel { MLXRuntimeSupport.clearCache() }
    }

    func prepare(choice: RAGEmbeddingChoice, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        try MLXRuntimeSupport.requireSupported()
        guard loadedEmbeddingID != choice.id else { return }
        unload()
        let loadingRevision = revision
        let loaded = try await EmbedderModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: choice.repositoryID),
            progressHandler: { [weak self] progress in
                let fractionCompleted = progress.fractionCompleted
                guard let self else { return }
                Task { @MainActor in
                    guard self.revision == loadingRevision else { return }
                    onProgress(min(max(fractionCompleted, 0), 1))
                }
            }
        )
        try Task.checkCancellation()
        guard revision == loadingRevision else { throw CancellationError() }
        embedder = loaded
        loadedEmbeddingID = choice.id
    }

    func embed(text: String, isQuery: Bool, choice: RAGEmbeddingChoice) async throws -> [Float] {
        guard let embedder, loadedEmbeddingID == choice.id else {
            throw EmbeddingServiceError.unavailable
        }
        let prefix = isQuery ? choice.queryPrefix : choice.passagePrefix
        return try await embedder.perform { context in
            let tokenIDs = context.tokenizer.encode(
                text: prefix + text,
                addSpecialTokens: true
            )
            guard !tokenIDs.isEmpty else {
                throw EmbeddingServiceError.tokenizationFailed
            }

            let inputs = stacked([MLXArray(tokenIDs)])
            let output = context.model(
                inputs,
                positionIds: nil,
                tokenTypeIds: nil,
                attentionMask: nil
            )
            let vector = context.pooling(output, normalize: true)
            vector.eval()
            return vector[0].asArray(Float.self)
        }
    }

}

nonisolated private enum EmbeddingServiceError: LocalizedError {
    case unavailable, tokenizationFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "Embedding modeli kullanılamıyor. Lütfen yeniden indeksleyin."
        case .tokenizationFailed: "Metin embedding modeli için hazırlanamadı."
        }
    }
}
