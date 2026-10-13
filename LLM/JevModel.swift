import Foundation
import Observation
import Security

enum JevQuestionType: String, CaseIterable, Identifiable {
    case noul
    case choice
    case score

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noul: "Evet / Hayır"
        case .choice: "Seçenek"
        case .score: "Puan"
        }
    }
}

enum JevProvider: String, CaseIterable, Identifiable {
    case typeSafe
    case liquidD1

    var id: String { rawValue }

    var title: String {
        switch self {
        case .typeSafe: "TypeSafe Jev"
        case .liquidD1: "Liquid d1"
        }
    }

    var modelName: String {
        switch self {
        case .typeSafe: "jev-latest"
        case .liquidD1: "d1"
        }
    }
}

@Observable
@MainActor
final class JevModel {
    var provider: JevProvider = JevProvider(
        rawValue: UserDefaults.standard.string(forKey: "jev.provider") ?? ""
    ) ?? .typeSafe {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "jev.provider") }
    }
    var apiKey: String
    var liquidAPIKey: String
    var questionType: JevQuestionType = .noul
    var stateText = ""
    var instructions = ""
    var criteriaText = ""
    var isBusy = false
    var statusMessage: String?
    var errorMessage: String?
    var jevAnswer: JevAnswer?
    var jevModelVersion: String?
    var jevAnswerProvider: JevProvider?
    var localExplanation = ""
    private var storedAPIKey = ""
    private var storedLiquidAPIKey = ""
    var hasSavedAPIKey: Bool {
        !storedAPIKey.isEmpty && apiKey == storedAPIKey
    }
    var hasSavedLiquidAPIKey: Bool {
        !storedLiquidAPIKey.isEmpty && liquidAPIKey == storedLiquidAPIKey
    }
    var selectedAPIKey: String {
        provider == .typeSafe ? apiKey : liquidAPIKey
    }
    var hasSavedSelectedAPIKey: Bool {
        provider == .typeSafe ? hasSavedAPIKey : hasSavedLiquidAPIKey
    }
    var providerResultTitle: String {
        "\(jevAnswerProvider?.title ?? provider.title) sonucu"
    }
    var explanationProviderTitle: String {
        (jevAnswerProvider ?? provider).title
    }

    private let keychain = JevAPIKeyStore(account: "typesafe-jev-api-key")
    private let liquidKeychain = JevAPIKeyStore(account: "liquid-d1-api-key")
    private let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private let liquidEndpoint = URL(string: "https://api.liquid.ai/decisions/v1/systemone")!

    init() {
        do {
            let storedKey = try keychain.read() ?? ""
            let storedLiquidKey = try liquidKeychain.read() ?? ""
            apiKey = storedKey
            liquidAPIKey = storedLiquidKey
            self.storedAPIKey = storedKey
            self.storedLiquidAPIKey = storedLiquidKey
        } catch {
            apiKey = ""
            liquidAPIKey = ""
            errorMessage = error.localizedDescription
        }
    }

    func saveAPIKey() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            errorMessage = "Kaydetmeden önce Jev API anahtarını girin."
            return
        }
        do {
            try keychain.save(trimmedKey)
            apiKey = trimmedKey
            storedAPIKey = trimmedKey
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAPIKey() {
        do {
            try keychain.delete()
            apiKey = ""
            storedAPIKey = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveLiquidAPIKey() {
        let trimmedKey = liquidAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            errorMessage = "Kaydetmeden önce Liquid API anahtarını girin."
            return
        }
        do {
            try liquidKeychain.save(trimmedKey)
            liquidAPIKey = trimmedKey
            storedLiquidAPIKey = trimmedKey
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteLiquidAPIKey() {
        do {
            try liquidKeychain.delete()
            liquidAPIKey = ""
            storedLiquidAPIKey = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func run(using chat: LocalChatModel, history: ConversationHistoryStore) async {
        guard !isBusy, !chat.isBusy else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        errorMessage = nil
        jevAnswer = nil
        jevModelVersion = nil
        jevAnswerProvider = nil
        localExplanation = ""

        let state = stateText.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructionsText = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isEmpty else {
            errorMessage = "Jev'in değerlendireceği metni girin."
            return
        }
        guard !instructionsText.isEmpty else {
            errorMessage = "Jev'e sorulacak değerlendirme sorusunu yazın."
            return
        }
        let trimmedKey = selectedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            errorMessage = provider == .typeSafe
                ? "Önce TypeSafe Jev API anahtarınızı girip kaydedin."
                : "Önce Liquid API anahtarınızı girip kaydedin."
            return
        }

        do {
            let requestQuestion = try makeQuestion(instructions: instructionsText)
            isBusy = true
            defer {
                isBusy = false
                statusMessage = nil
            }

            let response: JevResponse
            switch provider {
            case .typeSafe:
                try keychain.save(trimmedKey)
                apiKey = trimmedKey
                storedAPIKey = trimmedKey
                statusMessage = "1/2 · TypeSafe Jev değerlendirme yapıyor…"
                response = try await requestJev(state: state, question: requestQuestion, apiKey: trimmedKey)
            case .liquidD1:
                try liquidKeychain.save(trimmedKey)
                liquidAPIKey = trimmedKey
                storedLiquidAPIKey = trimmedKey
                statusMessage = "1/2 · Liquid d1 değerlendirme yapıyor…"
                response = try await requestLiquidD1(state: state, question: requestQuestion, apiKey: trimmedKey)
            }
            let firstResponseSeconds = ProcessInfo.processInfo.systemUptime - startedAt
            guard let result = response.answers["evaluation"] else {
                throw JevError.missingAnswer
            }
            jevAnswer = result
            jevModelVersion = response.model
            jevAnswerProvider = provider

            let resultJSON = try Self.prettyJSON(response)
            statusMessage = "2/2 · Seçili yerel model sonucu açıklıyor…"
            let explanation = try await chat.answerWithContext(
                question: "\(provider.title) yapılandırılmış değerlendirme sonucunu Türkçe ve anlaşılır biçimde açıkla. Seçilen sonucu ve varsa olasılık/güven değerlerini olduğu gibi aktar; sonucu değiştirecek yeni bir karar üretme.",
                context: """
                Değerlendirme sağlayıcısı: \(provider.title)

                Gönderilen içerik:
                \(state)

                Sorulan değerlendirme:
                \(instructionsText)

                Yapılandırılmış yanıt:
                \(resultJSON)
                """,
                startedAt: startedAt
            )
            localExplanation = explanation.text
            history.add(
                kind: .jev,
                title: instructionsText,
                prompt: "\(instructionsText)\n\nDeğerlendirilen içerik:\n\(state)",
                answer: explanation.text,
                details: "Değerlendirme modeli: \(response.model ?? provider.modelName)\n\n\(resultJSON)",
                modelName: "\(provider.title) (\(response.model ?? provider.modelName)) + \(chat.selectedModel.title)",
                totalDurationSeconds: explanation.totalDurationSeconds,
                firstResponseSeconds: firstResponseSeconds
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeQuestion(instructions: String) throws -> JevQuestion {
        switch questionType {
        case .noul:
            return JevQuestion(type: .noul, instructions: instructions)
        case .choice:
            var criteria: [String: String] = [:]
            for line in criteriaText.components(separatedBy: .newlines) {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !value.isEmpty {
                    criteria[key] = value
                }
            }
            guard criteria.count >= 2 else {
                throw JevError.invalidChoiceCriteria
            }
            guard criteria.count <= 255 else {
                throw JevError.tooManyChoiceCriteria
            }
            return JevQuestion(type: .choice, instructions: instructions, choiceCriteria: criteria)
        case .score:
            let criteria = criteriaText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard (2...10).contains(criteria.count) else {
                throw JevError.invalidScoreCriteria
            }
            return JevQuestion(type: .score, instructions: instructions, scoreCriteria: criteria)
        }
    }

    private func requestJev(state: String, question: JevQuestion, apiKey: String) async throws -> JevResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JevRequest(
                model: "jev-latest",
                state: state,
                questions: ["evaluation": question]
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JevError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(decoding: data.prefix(1200), as: UTF8.self)
            throw JevError.serverRejected(httpResponse.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(JevResponse.self, from: data)
        } catch {
            throw JevError.invalidResponseBody(error.localizedDescription)
        }
    }

    private func requestLiquidD1(
        state: String,
        question: JevQuestion,
        apiKey: String
    ) async throws -> JevResponse {
        var request = URLRequest(url: liquidEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JevRequest(
                model: "d1",
                state: state,
                questions: ["evaluation": question]
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JevError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(decoding: data.prefix(1200), as: UTF8.self)
            throw JevError.serverRejected(httpResponse.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(JevResponse.self, from: data)
        } catch {
            throw JevError.invalidResponseBody(error.localizedDescription)
        }
    }

    private static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private struct JevRequest: Encodable {
    let model: String
    let state: String
    let questions: [String: JevQuestion]
}

private struct JevQuestion: Encodable {
    let type: JevQuestionType
    let instructions: String
    var choiceCriteria: [String: String]?
    var scoreCriteria: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case instructions
        case criteria
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type.rawValue, forKey: .type)
        try container.encode(instructions, forKey: .instructions)
        if let choiceCriteria {
            try container.encode(choiceCriteria, forKey: .criteria)
        } else if let scoreCriteria {
            try container.encode(scoreCriteria, forKey: .criteria)
        }
    }
}

struct JevResponse: Codable {
    var model: String?
    var answers: [String: JevAnswer]
    var usage: JevUsage?
}

struct JevAnswer: Codable {
    var type: String?
    var choice: String?
    var score: Double?
    var noul: Double?
    var confidence: Double?
    var probabilities: [String: Double]?
    var legend: [String: String]?

    var summary: String {
        if let choice {
            "Seçim: \(choice)" + confidenceSummary
        } else if let score {
            "Puan: \(score.formatted())" + confidenceSummary
        } else if let noul {
            "Evet olasılığı: \((noul * 100).formatted(.number.precision(.fractionLength(1))))%"
        } else {
            "Jev bir değerlendirme döndürdü."
        }
    }

    private var confidenceSummary: String {
        guard let confidence else { return "" }
        return " · Güven: \((confidence * 100).formatted(.number.precision(.fractionLength(1))))%"
    }
}

struct JevUsage: Codable {
    var inputTokens: Int?
    var outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

private struct JevAPIKeyStore {
    private let service = Bundle.main.bundleIdentifier ?? "LLM"
    private let account: String

    init(account: String) {
        self.account = account
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw JevError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw JevError.invalidStoredKey
        }
        return key
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw JevError.keychain(updateStatus)
        }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw JevError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw JevError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private enum JevError: LocalizedError {
    case invalidChoiceCriteria
    case tooManyChoiceCriteria
    case invalidScoreCriteria
    case invalidResponse
    case invalidResponseBody(String)
    case missingAnswer
    case serverRejected(Int, String)
    case keychain(OSStatus)
    case invalidStoredKey

    var errorDescription: String? {
        switch self {
        case .invalidChoiceCriteria:
            return "Seçenek türünde en az iki satır `anahtar: açıklama` biçiminde girin."
        case .tooManyChoiceCriteria:
            return "Seçenek türü en fazla 255 seçenek destekliyor."
        case .invalidScoreCriteria:
            return "Puan türünde 2 ile 10 arasında açıklama satırı girin."
        case .invalidResponse:
            return "Jev API geçerli bir yanıt döndürmedi."
        case .invalidResponseBody(let reason):
            return "Jev API yanıtı okunamadı: \(reason)"
        case .missingAnswer:
            return "Jev yanıtında beklenen değerlendirme bulunamadı."
        case .serverRejected(let status, let body):
            let responseText = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return responseText.isEmpty
                ? "Jev API isteği reddetti (HTTP \(status)). API anahtarınızı ve hesabınızı kontrol edin."
                : "Jev API isteği reddetti (HTTP \(status)): \(responseText)"
        case .keychain(let status):
            return "API anahtarı iPhone Anahtar Zinciri'ne kaydedilemedi (kod \(status))."
        case .invalidStoredKey:
            return "Anahtar Zinciri'ndeki Jev API anahtarı okunamadı."
        }
    }
}
