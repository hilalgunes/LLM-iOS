import Foundation
import MLXLMCommon

enum LocalModelChoice: String, CaseIterable, Identifiable {
    case apple
    case qwen
    case gemma
    case gemma4
    case qwen35

    var id: String {
        repositoryID
    }

    var repositoryID: String {
        switch self {
        case .apple:
            "apple-system"
        case .qwen:
            "mlx-community/Qwen3-0.6B-4bit"
        case .gemma:
            "mlx-community/gemma-3-1b-it-4bit"
        case .gemma4:
            "over-show/gemma-4-e2b-it-text-only-4bit"
        case .qwen35:
            "bobkitchen/Qwen3.5-2B-Text-4bit"
        }
    }

    var title: String {
        switch self {
        case .apple:
            "Apple Intelligence · Sistem modeli"
        case .qwen:
            "Qwen 3 · 0.6B"
        case .gemma:
            "Gemma 3 · 1B"
        case .gemma4:
        "Gemma 4 E2B · 4-bit · ~2,5 GB"
        case .qwen35:
        "Qwen 3.5 · 2B · 4-bit · ~1 GB"
        }
    }

    var shortTitle: String {
        switch self {
        case .apple:
            "Apple Intelligence"
        case .qwen:
            "Qwen 3"
        case .gemma:
            "Gemma 3"
        case .gemma4:
            "Gemma 4 E2B"
        case .qwen35:
            "Qwen 3.5 2B"
        }
    }

    var configuration: ModelConfiguration {
        switch self {
        case .gemma4:
            ModelConfiguration(
                id: repositoryID,
                extraEOSTokens: ["<turn|>"]
            )
        case .qwen35:
            ModelConfiguration(
                id: repositoryID,
                extraEOSTokens: ["<|im_end|>"]
            )
        case .apple, .qwen, .gemma:
            ModelConfiguration(id: repositoryID)
        }
    }
}

