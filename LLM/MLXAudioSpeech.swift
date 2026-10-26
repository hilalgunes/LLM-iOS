import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioTTS

/// Reuses weights across the streamed sentences of a reply.
actor MLXAudioSpeech {
    static let shared = MLXAudioSpeech()
    static let repositoryID = "mlx-community/OmniVoice-bf16"
    private var model: OmniVoiceModel?

    func unload() {
        model = nil
    }

    func synthesize(
        _ text: String,
        progress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws -> Data {
        #if targetEnvironment(simulator)
        throw LocalChatError.simulatorNotSupported
        #else
        if model == nil {
            await progress(0)
            guard let repo = Repo.ID(rawValue: Self.repositoryID) else {
                throw AudioGenerationError.invalidInput("Geçersiz ses modeli adresi")
            }
            _ = try await ModelUtils.resolveOrDownloadModel(
                client: HubClient(),
                repoID: repo,
                requiredExtension: "safetensors",
                additionalMatchingPatterns: ["audio_tokenizer/config.json", "audio_tokenizer/model.safetensors"],
                progressHandler: { value in progress(value.fractionCompleted) }
            )
            try Task.checkCancellation()
            await progress(nil)
            model = try await OmniVoiceModel.fromPretrained(Self.repositoryID)
        }
        try Task.checkCancellation()
        guard let model else { throw AudioGenerationError.modelNotInitialized("OmniVoice yüklenemedi") }
        let audio = try await model.generate(
            text: text,
            language: "tr",
            ovParameters: .fast
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try AudioUtils.writeWavFile(
            samples: audio.asArray(Float.self),
            sampleRate: model.sampleRate,
            fileURL: fileURL
        )
        return try Data(contentsOf: fileURL)
        #endif
    }
}
