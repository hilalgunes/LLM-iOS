# Local integration

Vendored from huggingface/AnyLanguageModel tag 1.0.0, commit
`80d50b0b22291d956d43f2c67ad1339c188084a3`. The upstream license is preserved.

Only Package.swift is changed: swift-huggingface's dependency floor is relaxed
from 1.0.0 to 0.8.1 to share the 0.x dependency required by MLX Audio Swift.
No optional package traits are enabled. The app does not compile or use this
package's Hugging Face / MLX adapter, so its 1.x-only calls are excluded.

The app uses the existing mlx-swift-lm MLXFoundationModels adapter through
AnyLanguageModel.FoundationLanguageModel on iOS 27. Apple Intelligence uses
AnyLanguageModel.SystemLanguageModel. Both use the same LanguageModelSession
and cumulative streaming API. Preserve this setup when updating dependencies;
enabling the optional MLX trait requires revisiting Hugging Face compatibility.

MLX Audio Swift is pinned to commit
`6fd938669e45412f5c35e011e7086ecd20397dbd` in the Xcode project.
Its OmniVoice-bf16 model downloads on first use with visible progress. Weights
are reused across streamed sentences, then released before the next chat request.
Sentence audio starts while the text reply is still streaming; OmniVoice uses
the upstream fast generation preset.
The upstream OmniVoice model card specifies CC-BY-NC model weights; evaluate
that license before using this demo's model in a commercial product.

Validation: generic iOS device build with Xcode 27. Physical-device checks are
still needed for MLX generation, Turkish pronunciation, memory and audio output.
