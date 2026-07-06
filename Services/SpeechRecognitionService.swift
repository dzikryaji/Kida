import AVFoundation
import Speech

enum SpeechRecognitionServiceError: LocalizedError {
    case speechNotAuthorized
    case microphoneNotAuthorized
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case audioEngineUnavailable

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized:
            return "Speech recognition permission is needed to hear questions."
        case .microphoneNotAuthorized:
            return "Microphone permission is needed to hear questions."
        case .recognizerUnavailable:
            return "Speech recognition is not available right now."
        case .onDeviceRecognitionUnavailable:
            return "On-device speech recognition is not available on this device or language."
        case .audioEngineUnavailable:
            return "The microphone could not start. Please try again."
        }
    }
}

final class SpeechRecognitionService: @unchecked Sendable {
    private let locale: Locale
    private let recognizer: SFSpeechRecognizer?
    private let requiresOnDeviceRecognition: Bool
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onTranscript: (@MainActor @Sendable (String) -> Void)?
    private var onFinish: (@MainActor @Sendable (String) -> Void)?
    private var onError: (@MainActor @Sendable (String) -> Void)?
    private var lastTranscript = ""
    private var hasInputTap = false
    private var didFinish = false

    var isListening: Bool {
        audioEngine.isRunning
    }

    init(
        locale: Locale = Locale(identifier: "en-US"),
        requiresOnDeviceRecognition: Bool = false
    ) {
        self.locale = locale
        recognizer = SFSpeechRecognizer(locale: locale)
        self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
    }

    func startListening(
        onTranscript: @escaping @MainActor @Sendable (String) -> Void,
        onFinish: @escaping @MainActor @Sendable (String) -> Void,
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) {
        guard !audioEngine.isRunning else {
            return
        }

        Task {
            do {
                try await ensurePermissions()
                do {
                    try startAudioRecognition(
                        onTranscript: onTranscript,
                        onFinish: onFinish,
                        onError: onError
                    )
                } catch {
                    cleanupAudioResources()
                    throw error
                }
            } catch {
                cleanupAudioResources()
                let message = Self.describe(error)
                Task { @MainActor in
                    onError(message)
                }
            }
        }
    }

    func stopListening(sendFinalTranscript: Bool) {
        finishRecognition(sendFinalTranscript: sendFinalTranscript)
    }

    private func ensurePermissions() async throws {
        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            throw SpeechRecognitionServiceError.speechNotAuthorized
        }

        let microphoneAllowed = await requestMicrophonePermission()
        guard microphoneAllowed else {
            throw SpeechRecognitionServiceError.microphoneNotAuthorized
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
    }

    private func startAudioRecognition(
        onTranscript: @escaping @MainActor @Sendable (String) -> Void,
        onFinish: @escaping @MainActor @Sendable (String) -> Void,
        onError: @escaping @MainActor @Sendable (String) -> Void
    ) throws {
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechRecognitionServiceError.recognizerUnavailable
        }
        if requiresOnDeviceRecognition, !recognizer.supportsOnDeviceRecognition {
            throw SpeechRecognitionServiceError.onDeviceRecognitionUnavailable
        }

        cleanupAudioResources()
        didFinish = false
        self.onTranscript = onTranscript
        self.onFinish = onFinish
        self.onError = onError

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = [
            "Kida",
            "What are you",
            "What do you do",
            "Tell me a fun fact"
        ]
        if requiresOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        if hasInputTap {
            inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw SpeechRecognitionServiceError.audioEngineUnavailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        hasInputTap = true

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else {
                return
            }

            if let result {
                let transcript = result.bestTranscription.formattedString
                self.lastTranscript = transcript
                self.deliverTranscript(transcript)

                if result.isFinal {
                    self.finishRecognition(sendFinalTranscript: true)
                }
            }

            if let error, !self.didFinish {
                self.finishRecognition(sendFinalTranscript: false)
                self.deliverError(Self.describe(error))
            }
        }
    }

    private func finishRecognition(sendFinalTranscript: Bool) {
        guard !didFinish else {
            return
        }

        didFinish = true

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.reset()
        }

        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let finalTranscript = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let finish = onFinish
        resetRecognitionState()

        if sendFinalTranscript {
            deliverFinish(finalTranscript, handler: finish)
        }
    }

    private func resetRecognitionState() {
        recognitionTask = nil
        recognitionRequest = nil
        onTranscript = nil
        onFinish = nil
        onError = nil
        lastTranscript = ""
    }

    private func cleanupAudioResources() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.reset()
        }

        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        resetRecognitionState()
    }

    private func deliverTranscript(_ transcript: String) {
        let handler = onTranscript
        Task { @MainActor in
            handler?(transcript)
        }
    }

    private func deliverFinish(_ transcript: String, handler: (@MainActor @Sendable (String) -> Void)? = nil) {
        let finishHandler = handler ?? onFinish
        Task { @MainActor in
            finishHandler?(transcript)
        }
    }

    private func deliverError(_ message: String) {
        let handler = onError
        Task { @MainActor in
            handler?(message)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let serviceError = error as? SpeechRecognitionServiceError {
            return serviceError.localizedDescription
        }

        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }
}
