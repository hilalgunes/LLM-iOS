import AVFoundation
import Observation
import Speech

enum SpeechEngine: String, CaseIterable, Identifiable {
    case system
    case ema
    case mlxAudio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "iOS sesi (Türkçe)"
        case .ema: "EMA (Türkçe)"
        case .mlxAudio: "MLX Audio · OmniVoice (Türkçe)"
        }
    }
}

@Observable
@MainActor
final class VoiceChatController: NSObject, AVAudioPlayerDelegate {
    var transcript = ""
    var isRecording = false
    var isFinishingRecognition = false
    var errorMessage: String?
    var speaksReplies = UserDefaults.standard.bool(forKey: "voice.speaksReplies") {
        didSet {
            UserDefaults.standard.set(speaksReplies, forKey: "voice.speaksReplies")
            if !speaksReplies { stopSpeaking() }
        }
    }
    var speechEngine: SpeechEngine = {
        if let saved = UserDefaults.standard.string(forKey: "voice.speechEngine"),
           let engine = SpeechEngine(rawValue: saved) {
            return engine
        }
        return UserDefaults.standard.bool(forKey: "voice.usesEMASpeech") ? .ema : .system
    }() {
        didSet {
            UserDefaults.standard.set(speechEngine.rawValue, forKey: "voice.speechEngine")
            if oldValue != speechEngine { stopSpeaking() }
        }
    }
    var usesEMASpeech: Bool { speechEngine == .ema }
    var usesLocalSpeechModel: Bool { speechEngine != .system }
    var speechPreparationMessage: String {
        if speechEngine == .mlxAudio {
            if let audioDownloadProgress {
                return "OmniVoice indiriliyor: %\(Int(audioDownloadProgress * 100)) — ilk kullanımda uzun sürebilir."
            }
            return "OmniVoice sesi hazırlanıyor…"
        }
        return "Türkçe ses hazırlanıyor; EMA ilk kullanımda model dosyalarını indirir…"
    }
    private(set) var audioDownloadProgress: Double?
    var isGeneratingSpeech = false

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var emaSpeechPlayer: AVAudioPlayer?
    private let emaSpeech = EMAOnnxSpeech.shared
    private let mlxSpeech = MLXAudioSpeech.shared
    private var speechChunks: [String] = []
    private var pendingSpeechText = ""
    private var shouldSpeakCurrentReply = false
    private var isDrainingEMAQueue = false
    private var speechGeneration = UUID()
    private var speechTask: Task<Void, Never>?
    private var emaPlaybackContinuation: CheckedContinuation<Void, Error>?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionID: UUID?
    private var hasInstalledInputTap = false
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))

    override init() {
        super.init()
    }

    func startRecording() async {
        guard !isRecording, !isFinishingRecognition else { return }
        stopSpeaking()
        errorMessage = nil

        do {
            try await requestPermissions()
            guard let recognizer, recognizer.isAvailable else {
                throw VoiceChatError.recognizerUnavailable
            }

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            recognitionRequest = request
            transcript = ""
            let currentRecognitionID = UUID()
            recognitionID = currentRecognitionID

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw VoiceChatError.microphoneUnavailable
            }
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            hasInstalledInputTap = true

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.recognitionID == currentRecognitionID else { return }
                    if let result {
                        let recognizedText = result.bestTranscription.formattedString
                        if !recognizedText.isEmpty {
                            self.transcript = recognizedText
                        }
                        if result.isFinal {
                            self.finishRecognition()
                            return
                        }
                    }
                    if let error {
                        if !self.isFinishingRecognition {
                            self.errorMessage = error.localizedDescription
                        }
                        self.finishRecognition(cancelTask: true)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            finishRecognition(cancelTask: true)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }
        recognitionRequest?.endAudio()
        isRecording = false
        isFinishingRecognition = true
    }

    private func finishRecognition(cancelTask: Bool = false) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledInputTap = false
        }
        recognitionRequest?.endAudio()
        if cancelTask {
            recognitionTask?.cancel()
        }
        recognitionRequest = nil
        recognitionTask = nil
        recognitionID = nil
        isRecording = false
        isFinishingRecognition = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Ses oturumu kapatılamadı: \(error.localizedDescription)"
        }
    }

    func speak(_ text: String) {
        beginStreamingReply()
        appendReplyText(text)
        finishStreamingReply()
    }

    func stopSpeaking() {
        speechTask?.cancel()
        speechGeneration = UUID()
        shouldSpeakCurrentReply = false
        pendingSpeechText = ""
        speechChunks.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        stopEMAPlayback()
        isDrainingEMAQueue = false
        isGeneratingSpeech = false
        audioDownloadProgress = nil
    }

    func beginStreamingReply() {
        errorMessage = nil
        speechTask?.cancel()
        speechGeneration = UUID()
        synthesizer.stopSpeaking(at: .immediate)
        stopEMAPlayback()
        speechChunks.removeAll()
        pendingSpeechText = ""
        isDrainingEMAQueue = false
        isGeneratingSpeech = false
        shouldSpeakCurrentReply = speaksReplies
    }

    func waitForSpeechCompletion() async {
        await speechTask?.value
        await mlxSpeech.unload()
    }

    func appendReplyText(_ token: String) {
        guard shouldSpeakCurrentReply else { return }
        pendingSpeechText += token

        while let boundary = pendingSpeechText.firstIndex(where: { ".?!\n".contains($0) }) {
            let endIndex = pendingSpeechText.index(after: boundary)
            let chunk = String(pendingSpeechText[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            pendingSpeechText = String(pendingSpeechText[endIndex...])
            guard !chunk.isEmpty else { continue }
            enqueueSpeech(chunk, startImmediately: true)
        }
    }

    func finishStreamingReply(success: Bool = true) {
        guard shouldSpeakCurrentReply else { return }
        if success {
            let remaining = pendingSpeechText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                enqueueSpeech(remaining, startImmediately: true)
            }
            if usesLocalSpeechModel, !speechChunks.isEmpty {
                startSpeechQueue()
            }
        } else {
            speechTask?.cancel()
            speechGeneration = UUID()
            speechChunks.removeAll()
            pendingSpeechText = ""
            synthesizer.stopSpeaking(at: .immediate)
            stopEMAPlayback()
            isGeneratingSpeech = false
        }
        shouldSpeakCurrentReply = false
    }

    private func stopEMAPlayback() {
        let continuation = emaPlaybackContinuation
        emaPlaybackContinuation = nil
        continuation?.resume(throwing: CancellationError())
        emaSpeechPlayer?.stop()
        emaSpeechPlayer = nil
    }

    private func enqueueSpeech(_ text: String, startImmediately: Bool) {
        guard usesLocalSpeechModel else {
            do {
                try preparePlayback()
            } catch {
                shouldSpeakCurrentReply = false
                pendingSpeechText = ""
                errorMessage = SpeechFailure.describe(error, stage: "iOS sesi: ses çıkışı başlatılamadı.")
                return
            }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "tr-TR")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            synthesizer.speak(utterance)
            return
        }

        speechChunks.append(text)
        guard startImmediately else { return }
        startSpeechQueue()
    }

    private func startSpeechQueue() {
        guard !isDrainingEMAQueue, !speechChunks.isEmpty else { return }
        isDrainingEMAQueue = true
        isGeneratingSpeech = true
        let currentGeneration = speechGeneration
        let engine = speechEngine
        let previousTask = speechTask
        speechTask = Task {
            await previousTask?.value
            while speechGeneration == currentGeneration, !speechChunks.isEmpty {
                let nextChunk = speechChunks.removeFirst()
                var stage = "model yükleme / ses üretimi"
                do {
                    let waveFile: Data
                    if engine == .mlxAudio {
                        waveFile = try await mlxSpeech.synthesize(nextChunk) { [weak self] progress in
                            guard let self, self.speechGeneration == currentGeneration else { return }
                            self.audioDownloadProgress = progress.map { min(max($0, 0), 1) }
                        }
                    } else {
                        waveFile = try await emaSpeech.synthesize(nextChunk)
                    }
                    guard speechGeneration == currentGeneration else { break }
                    stage = "ses dosyasını oynatma"
                    try await playEMA(waveFile)
                } catch is CancellationError {
                    break
                } catch {
                    if speechGeneration == currentGeneration {
                        speechChunks.removeAll()
                        shouldSpeakCurrentReply = false
                        pendingSpeechText = ""
                        errorMessage = SpeechFailure.describe(error, stage: "\(engine.title): \(stage) başarısız.")
                    }
                    break
                }
            }
            if speechGeneration == currentGeneration {
                isDrainingEMAQueue = false
                isGeneratingSpeech = false
                audioDownloadProgress = nil
                speechTask = nil
            }
        }
    }

    private func playEMA(_ waveFile: Data) async throws {
        try preparePlayback()
        let player = try AVAudioPlayer(data: waveFile)
        player.delegate = self
        player.prepareToPlay()
        emaSpeechPlayer = player
        try await withCheckedThrowingContinuation { continuation in
            emaPlaybackContinuation = continuation
            guard player.play() else {
                emaPlaybackContinuation = nil
                continuation.resume(throwing: VoiceChatError.audioPlaybackFailed)
                return
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === emaSpeechPlayer else { return }
        guard let continuation = emaPlaybackContinuation else { return }
        emaPlaybackContinuation = nil
        if flag {
            continuation.resume()
        } else {
            continuation.resume(throwing: VoiceChatError.audioPlaybackFailed)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === emaSpeechPlayer else { return }
        guard let continuation = emaPlaybackContinuation else { return }
        emaPlaybackContinuation = nil
        continuation.resume(throwing: error ?? VoiceChatError.audioPlaybackFailed)
    }

    private func preparePlayback() throws {
        let session = AVAudioSession.sharedInstance()
        // Reset the recording mode/options before activating output. Configure once
        // per route, rather than reconfiguring it for each streamed sentence.
        if session.category != .playback || session.mode != .default || !session.categoryOptions.isEmpty {
            try session.setCategory(.playback, mode: .default, options: [])
        }
        try session.setActive(true)
    }

    private func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw VoiceChatError.speechPermissionDenied
        }

        let microphoneGranted = await AVAudioApplication.requestRecordPermission()
        guard microphoneGranted else {
            throw VoiceChatError.microphonePermissionDenied
        }
    }
}

private enum VoiceChatError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable
    case microphoneUnavailable
    case audioPlaybackFailed

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            "Ses tanıma izni kapalı. Ayarlar'dan bu uygulama için Ses Tanıma iznini açın."
        case .microphonePermissionDenied:
            "Mikrofon izni kapalı. Ayarlar'dan bu uygulama için Mikrofon iznini açın."
        case .recognizerUnavailable:
            "Türkçe ses tanıma şu anda kullanılamıyor. İnternet bağlantınızı kontrol edip yeniden deneyin."
        case .microphoneUnavailable:
            "Mikrofon başlatılamadı."
        case .audioPlaybackFailed:
            "Üretilen EMA sesi çalınamadı."
        }
    }
}
