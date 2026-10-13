import Foundation
import OnnxRuntimeBindings

actor EMAOnnxSpeech {
    static let shared = EMAOnnxSpeech()

    private struct Metadata: Decodable {
        let vocab: [String]
        let times: [Float]
        let latent_dim: Int
        let hop: Int
        let sample_rate: Int
    }

    private let repository = "https://huggingface.co/ozcancelik/ema-lightning-onnx/resolve/main/"
    private let fileManager = FileManager.default
    private var environment: ORTEnv?
    private var textSession: ORTSession?
    private var soundSession: ORTSession?
    private var decoderSession: ORTSession?
    private var metadata: Metadata?
    private var vocabulary: [String: Int] = [:]
    private var allowedCharacters = Set<Character>()

    func synthesize(_ text: String) async throws -> Data {
        try await loadModelsIfNeeded()
        guard let metadata, let textSession, let soundSession, let decoderSession else {
            throw EMAOnnxSpeechError.modelUnavailable
        }

        let pieces = try makePieces(from: text)
        guard !pieces.isEmpty else {
            throw EMAOnnxSpeechError.emptyText
        }

        var samples: [Float] = []
        for piece in pieces {
            let ids = piece.compactMap { vocabulary[String($0)] }
            guard ids.count == piece.count else {
                throw EMAOnnxSpeechError.invalidText
            }

            let wordInfo = makeWordInfo(Array(piece))
            let textOutputs = try run(
                textSession,
                inputs: ["ids": try tensor(ids.map(Int64.init), shape: [1, ids.count])],
                outputs: ["h", "dur"]
            )
            guard let hidden = textOutputs["h"], let durations = textOutputs["dur"] else {
                throw EMAOnnxSpeechError.invalidModelOutput
            }
            let durationValues = try floatValues(from: durations)
            let plan = makePlan(
                wordIDs: wordInfo.wordIDs,
                wordStarts: wordInfo.wordStarts,
                durations: durationValues
            )
            let noise = gaussianNoise(count: metadata.times.count * plan.frameCount * metadata.latent_dim)
            let soundOutputs = try run(
                soundSession,
                inputs: [
                    "h": hidden,
                    "cg": try tensor(plan.letterPositions, shape: [1, plan.letterPositions.count]),
                    "fg": try tensor(plan.framePositions, shape: [1, plan.frameCount]),
                    "cw": try tensor(wordInfo.wordIDs.map(Int64.init), shape: [1, wordInfo.wordIDs.count]),
                    "fw": try tensor(plan.frameWordIDs.map(Int64.init), shape: [1, plan.frameCount]),
                    "noise": try tensor(
                        noise,
                        shape: [1, metadata.times.count, plan.frameCount, metadata.latent_dim]
                    ),
                ],
                outputs: ["latents"]
            )
            guard let latentValue = soundOutputs["latents"] else {
                throw EMAOnnxSpeechError.invalidModelOutput
            }
            let latents = try floatValues(from: latentValue)
            samples.append(contentsOf: try decode(
                latents: latents,
                frameCount: plan.frameCount,
                latentSize: metadata.latent_dim,
                hop: metadata.hop,
                session: decoderSession
            ))
        }
        return makeWaveFile(samples: samples, sampleRate: metadata.sample_rate)
    }

    private func loadModelsIfNeeded() async throws {
        guard textSession == nil || soundSession == nil || decoderSession == nil else { return }
        let directory = try modelDirectory()
        let fileNames = ["meta.json", "text.onnx", "sound.onnx", "decoder.onnx"]
        for name in fileNames {
            let destination = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) { continue }
            guard let url = URL(string: repository + name) else {
                throw EMAOnnxSpeechError.invalidModelURL
            }
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw EMAOnnxSpeechError.downloadFailed(name)
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }

        let metadataData = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        let loadedMetadata = try JSONDecoder().decode(Metadata.self, from: metadataData)
        let env = try ORTEnv(loggingLevel: ORTLoggingLevel.error)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)

        environment = env
        textSession = try ORTSession(
            env: env,
            modelPath: directory.appendingPathComponent("text.onnx").path,
            sessionOptions: options
        )
        soundSession = try ORTSession(
            env: env,
            modelPath: directory.appendingPathComponent("sound.onnx").path,
            sessionOptions: options
        )
        decoderSession = try ORTSession(
            env: env,
            modelPath: directory.appendingPathComponent("decoder.onnx").path,
            sessionOptions: options
        )
        metadata = loadedMetadata
        vocabulary = Dictionary(uniqueKeysWithValues: loadedMetadata.vocab.enumerated().map { ($0.element, $0.offset) })
        allowedCharacters = Set(loadedMetadata.vocab.compactMap { $0.count == 1 ? $0.first : nil })
    }

    private func modelDirectory() throws -> URL {
        let supportDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = supportDirectory.appendingPathComponent("EMA-Lightning-ONNX", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var excludedDirectory = directory
        try excludedDirectory.setResourceValues(resourceValues)
        return directory
    }

    private func makePieces(from text: String) throws -> [[Character]] {
        let replacements: [Character: String] = [
            "’": "'", "‘": "'", "ʼ": "'", "´": "'", "`": "'", "“": "\"", "”": "\"",
            "„": "\"", "«": "\"", "»": "\"", "–": "-", "—": "-", "−": "-", "…": "...",
        ]
        let expandedNumbers = try normalizeNumbers(in: text)
        let normalized = String(expandedNumbers.map { replacements[$0] ?? String($0) }.joined())
            .replacingOccurrences(of: "İ", with: "i")
            .replacingOccurrences(of: "I", with: "ı")
            .lowercased(with: Locale(identifier: "tr_TR"))
            .precomposedStringWithCanonicalMapping
        let filtered = normalized.map { allowedCharacters.contains($0) ? $0 : " " }
        let content = String(filtered).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !content.isEmpty else { return [] }

        let characters = Array(content)
        var pieces: [[Character]] = []
        var start = 0
        while start < characters.count {
            let end = min(start + 180, characters.count)
            var cut = end
            if end < characters.count,
               let boundary = (start..<end).reversed().first(where: { characters[$0].isWhitespace }) {
                cut = boundary
            }
            var piece = Array(characters[start..<cut])
            while piece.first?.isWhitespace == true { piece.removeFirst() }
            while piece.last?.isWhitespace == true { piece.removeLast() }
            if piece.isEmpty {
                start = cut + 1
                continue
            }
            if let last = piece.last, !".!?".contains(last) {
                piece.append(".")
            }
            pieces.append(piece)
            start = cut
            while start < characters.count, characters[start].isWhitespace { start += 1 }
        }
        return pieces
    }

    private func normalizeNumbers(in text: String) throws -> String {
        let expression = try NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.numberStyle = .spellOut
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            let parts = token.split(whereSeparator: { $0 == "." || $0 == "," })
            let spoken: String
            if parts.count > 2 {
                spoken = try parts.map { try spellOut(String($0), formatter: formatter) }.joined(separator: " ")
            } else if token.contains(".") || token.contains(",") {
                guard let number = Double(token.replacingOccurrences(of: ",", with: ".")),
                      let words = formatter.string(from: NSNumber(value: number)) else {
                    throw EMAOnnxSpeechError.numberNormalizationFailed
                }
                spoken = words
            } else {
                spoken = try spellOut(token, formatter: formatter)
            }
            result.replaceSubrange(range, with: spoken)
        }
        return result
    }

    private func spellOut(_ digits: String, formatter: NumberFormatter) throws -> String {
        guard let number = Double(digits),
              let words = formatter.string(from: NSNumber(value: number)) else {
            throw EMAOnnxSpeechError.numberNormalizationFailed
        }
        return words
    }

    private func makeWordInfo(_ text: [Character]) -> (wordIDs: [Int], wordStarts: [Int]) {
        var starts = text.indices.filter {
            text[$0] != " " && ($0 == 0 || text[$0 - 1] == " ")
        }
        if starts.isEmpty { starts = [0] }
        let boundaries = [0] + starts.dropFirst() + [text.count]
        var wordIDs: [Int] = []
        var wordStarts: [Int] = []
        for word in 0..<(boundaries.count - 1) {
            for _ in boundaries[word]..<boundaries[word + 1] {
                wordIDs.append(word)
                wordStarts.append(boundaries[word])
            }
        }
        return (wordIDs, wordStarts)
    }

    private struct FramePlan {
        let frameCount: Int
        let frameWordIDs: [Int]
        let letterPositions: [Float]
        let framePositions: [Float]
    }

    private func makePlan(wordIDs: [Int], wordStarts: [Int], durations: [Float]) -> FramePlan {
        let lettersCount = wordIDs.count
        let wordsCount = (wordIDs.last ?? 0) + 1
        var durationSums = Array(repeating: 0.0, count: wordsCount)
        let scaledDurations = durations.map { max(Double($0), 0.0001) }
        for index in 0..<min(lettersCount, scaledDurations.count) {
            durationSums[wordIDs[index]] += scaledDurations[index]
        }
        let counts = durationSums.map { min(250, max(1, Int($0.rounded()))) }
        let frameCount = min(counts.reduce(0, +), 3000)
        var frameWordIDs = Array(repeating: 0, count: frameCount)
        var frameFraction = Array(repeating: Float.zero, count: frameCount)
        var starts: [Int] = []
        var frame = 0
        for (word, count) in counts.enumerated() {
            starts.append(frame)
            for position in 0..<count where frame < frameCount {
                frameWordIDs[frame] = word
                frameFraction[frame] = Float(position) / Float(count)
                frame += 1
            }
        }

        var cumulative = Array(repeating: 0.0, count: lettersCount)
        var totals = Array(repeating: 0.0, count: wordsCount)
        var accumulator = 0.0
        for index in 0..<lettersCount {
            accumulator += scaledDurations[index]
            cumulative[index] = accumulator
            totals[wordIDs[index]] += scaledDurations[index]
        }
        var wordLengths = Array(repeating: 0.0, count: wordsCount)
        for word in wordIDs { wordLengths[word] += 1 }
        var wordOffsets = Array(repeating: 0.0, count: wordsCount)
        if wordsCount > 1 {
            for word in 1..<wordsCount {
                wordOffsets[word] = wordOffsets[word - 1] + max(wordLengths[word - 1], 1)
            }
        }

        var letterPositions = Array(repeating: Float.zero, count: lettersCount)
        for index in 0..<lettersCount {
            let word = wordIDs[index]
            let previousIndex = max(0, min(wordStarts[index], cumulative.count - 1))
            let previous = cumulative[previousIndex] - scaledDurations[previousIndex]
            let fraction = min(
                1,
                max(0, (cumulative[index] - previous - 0.5 * scaledDurations[index]) / max(totals[word], 1e-8))
            )
            letterPositions[index] = Float(wordOffsets[word] + fraction * max(wordLengths[word], 1))
        }
        let framePositions = (0..<frameCount).map { index in
            Float(wordOffsets[frameWordIDs[index]] + Double(frameFraction[index]) * max(wordLengths[frameWordIDs[index]], 1))
        }
        return FramePlan(
            frameCount: frameCount,
            frameWordIDs: frameWordIDs,
            letterPositions: letterPositions,
            framePositions: framePositions
        )
    }

    private func decode(
        latents: [Float],
        frameCount: Int,
        latentSize: Int,
        hop: Int,
        session: ORTSession
    ) throws -> [Float] {
        let firstWindow = 25
        let windowSize = 100
        let context = 8
        var samples: [Float] = []
        var start = 0
        while start < frameCount {
            let end = min(frameCount, start + (start == 0 ? firstWindow : windowSize))
            let left = max(0, start - context)
            let right = min(frameCount, end + context)
            let windowFrames = right - left
            var input = Array(repeating: Float.zero, count: latentSize * windowFrames)
            for frame in 0..<windowFrames {
                for dimension in 0..<latentSize {
                    input[dimension * windowFrames + frame] = latents[(left + frame) * latentSize + dimension]
                }
            }
            let outputs = try run(
                session,
                inputs: ["z": try tensor(input, shape: [1, latentSize, windowFrames])],
                outputs: ["audio"]
            )
            guard let audio = outputs["audio"] else { throw EMAOnnxSpeechError.invalidModelOutput }
            let decoded = try floatValues(from: audio)
            let trimStart = (start - left) * hop
            let count = (end - start) * hop
            guard decoded.count >= trimStart + count else {
                throw EMAOnnxSpeechError.invalidModelOutput
            }
            samples.append(contentsOf: decoded[trimStart..<(trimStart + count)])
            start = end
        }
        return samples
    }

    private func run(
        _ session: ORTSession,
        inputs: [String: ORTValue],
        outputs: Set<String>
    ) throws -> [String: ORTValue] {
        try session.run(withInputs: inputs, outputNames: outputs, runOptions: nil)
    }

    private func tensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { buffer in
            NSMutableData(bytes: buffer.baseAddress!, length: buffer.count * MemoryLayout<Float>.size)
        }
        return try ORTValue(
            tensorData: data,
            elementType: .float,
            shape: shape.map(NSNumber.init(value:))
        )
    }

    private func tensor(_ values: [Int64], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { buffer in
            NSMutableData(bytes: buffer.baseAddress!, length: buffer.count * MemoryLayout<Int64>.size)
        }
        return try ORTValue(
            tensorData: data,
            elementType: .int64,
            shape: shape.map(NSNumber.init(value:))
        )
    }

    private func floatValues(from value: ORTValue) throws -> [Float] {
        let data = try value.tensorData()
        let count = data.length / MemoryLayout<Float>.size
        let rawData = data as Data
        return rawData.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self).prefix(count))
        }
    }

    private func gaussianNoise(count: Int) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        var result: [Float] = []
        result.reserveCapacity(count)
        while result.count < count {
            let first = max(Double.random(in: 0..<1, using: &generator), Double.leastNonzeroMagnitude)
            let second = Double.random(in: 0..<1, using: &generator)
            let radius = sqrt(-2 * log(first))
            result.append(Float(radius * cos(2 * .pi * second)))
            if result.count < count {
                result.append(Float(radius * sin(2 * .pi * second)))
            }
        }
        return result
    }

    private func makeWaveFile(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(byteCount)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            let pcm = Int16(clipped * (clipped < 0 ? 32768 : 32767))
            data.appendLittleEndian(UInt16(bitPattern: pcm))
        }
        return data
    }
}

private extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }
}

private enum EMAOnnxSpeechError: LocalizedError {
    case downloadFailed(String)
    case emptyText
    case invalidModelOutput
    case invalidModelURL
    case invalidTensor
    case invalidText
    case modelUnavailable
    case numberNormalizationFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let file):
            "EMA modeli indirilemedi (\(file)). İnternet bağlantınızı kontrol edip tekrar deneyin."
        case .emptyText:
            "Seslendirilecek Türkçe metin bulunamadı."
        case .invalidModelOutput:
            "EMA modeli beklenmeyen bir çıktı üretti."
        case .invalidModelURL:
            "EMA model adresi geçersiz."
        case .invalidTensor:
            "EMA modeli için giriş verisi hazırlanamadı."
        case .invalidText:
            "Metin, EMA modelinin desteklediği alfabeye dönüştürülemedi."
        case .modelUnavailable:
            "EMA modeli kullanıma hazır değil."
        case .numberNormalizationFailed:
            "Bir sayı Türkçe konuşma biçimine dönüştürülemedi. Bu cümleyi sistem seslendirmesiyle deneyin."
        }
    }
}
