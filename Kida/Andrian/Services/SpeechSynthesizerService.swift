import AVFoundation

final class SpeechSynthesizerService: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var elevenLabsTask: Task<Void, Never>?
    private var mouthApproximationTask: Task<Void, Never>?
    private var onStart: (() -> Void)?
    private var onWord: ((String, NSRange) -> Void)?
    private var onFinish: (() -> Void)?
    private var onError: ((String) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        if #available(iOS 13.0, *) {
            synthesizer.usesApplicationAudioSession = true
        }
    }

    func speak(
        text: String,
        voiceProfile: VoiceProfile,
        onStart: @escaping () -> Void,
        onWord: @escaping (String, NSRange) -> Void,
        onFinish: @escaping () -> Void,
        onError: ((String) -> Void)? = nil
    ) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            finishSpeech()
        }

        self.onStart = onStart
        self.onWord = onWord
        self.onFinish = onFinish
        self.onError = onError

        if let elevenLabsConfiguration = ElevenLabsConfiguration.load() {
            speakWithElevenLabs(
                text: text,
                voiceProfile: voiceProfile,
                configuration: elevenLabsConfiguration
            )
            return
        }

        speakWithApple(text: text, voiceProfile: voiceProfile)
    }

    func stop() {
        elevenLabsTask?.cancel()
        elevenLabsTask = nil
        mouthApproximationTask?.cancel()
        mouthApproximationTask = nil

        if let audioPlayer, audioPlayer.isPlaying {
            audioPlayer.stop()
            self.audioPlayer = nil
            finishSpeech()
        }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            finishSpeech()
        }
    }

    private func speakWithElevenLabs(
        text: String,
        voiceProfile: VoiceProfile,
        configuration: ElevenLabsConfiguration
    ) {
        let client = ElevenLabsSpeechClient(configuration: configuration)

        elevenLabsTask = Task { [weak self] in
            do {
                let audioData = try await client.speechData(for: text, voiceProfile: voiceProfile)
                guard !Task.isCancelled else {
                    return
                }

                self?.playElevenLabsAudio(audioData, sourceText: text)
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                self?.onError?("ElevenLabs failed. Using Apple voice.")
                self?.speakWithApple(text: text, voiceProfile: voiceProfile)
            }
        }
    }

    private func playElevenLabsAudio(_ audioData: Data, sourceText: String) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
            let player = try AVAudioPlayer(data: audioData)
            player.delegate = self
            player.prepareToPlay()
            audioPlayer = player
            onStart?()
            startApproximateMouthTiming(for: sourceText, duration: player.duration)
            player.play()
        } catch {
            onError?("Speech audio could not start: \(Self.describe(error))")
            finishSpeech()
        }
    }

    private func speakWithApple(text: String, voiceProfile: VoiceProfile) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            onError?("Speech audio could not start: \(Self.describe(error))")
            finishSpeech()
            return
        }

        let selectedVoice = selectVoice(for: voiceProfile)
        let utterance = makeUtterance(
            text: text,
            voiceProfile: voiceProfile,
            selectedVoice: selectedVoice
        )
        if let voice = selectedVoice {
            utterance.voice = voice
        }

        utterance.rate = naturalRate(from: voiceProfile.rate)
        utterance.pitchMultiplier = naturalPitch(from: voiceProfile.pitch)
        utterance.volume = min(max(voiceProfile.volume, 0.0), 1.0)
        utterance.preUtteranceDelay = 0.04
        utterance.postUtteranceDelay = 0.08

        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onStart?()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard let range = Range(characterRange, in: utterance.speechString) else {
            return
        }

        onWord?(String(utterance.speechString[range]), characterRange)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        finishSpeech()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        finishSpeech()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioPlayer = nil
        finishSpeech()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioPlayer = nil
        if let error {
            onError?("ElevenLabs audio decode failed: \(Self.describe(error))")
        }
        finishSpeech()
    }

    private func finishSpeech() {
        mouthApproximationTask?.cancel()
        mouthApproximationTask = nil
        let finish = onFinish
        onStart = nil
        onWord = nil
        onFinish = nil
        onError = nil
        finish?()
    }

    private func makeUtterance(
        text: String,
        voiceProfile: VoiceProfile,
        selectedVoice: AVSpeechSynthesisVoice?
    ) -> AVSpeechUtterance {
        if #available(iOS 16.0, *) {
            let ssml = ssmlText(
                from: text,
                voiceProfile: voiceProfile,
                selectedVoice: selectedVoice
            )

            if let utterance = AVSpeechUtterance(ssmlRepresentation: ssml) {
                return utterance
            }
        }

        return AVSpeechUtterance(string: text)
    }

    private func startApproximateMouthTiming(for text: String, duration: TimeInterval) {
        mouthApproximationTask?.cancel()

        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        guard !words.isEmpty else {
            return
        }

        let interval = max(0.10, min(0.24, duration / Double(words.count)))
        mouthApproximationTask = Task { [weak self] in
            var searchStart = 0
            let nsText = text as NSString

            for word in words {
                guard !Task.isCancelled else {
                    return
                }

                let remainingRange = NSRange(
                    location: min(searchStart, nsText.length),
                    length: max(nsText.length - searchStart, 0)
                )
                let range = nsText.range(of: word, options: [], range: remainingRange)
                if range.location != NSNotFound {
                    searchStart = range.location + range.length
                    self?.onWord?(word, range)
                } else {
                    self?.onWord?(word, NSRange(location: 0, length: word.count))
                }

                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func selectVoice(for profile: VoiceProfile) -> AVSpeechSynthesisVoice? {
        if let identifier = profile.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }

        let voices = AVSpeechSynthesisVoice.speechVoices()
        let englishVoices = voices.filter { voice in
            voice.language == "en-US" || voice.language.hasPrefix("en-")
        }

        if let bestVoice = englishVoices.max(by: { score($0) < score($1) }) {
            return bestVoice
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private func score(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0

        if voice.language == "en-US" {
            score += 120
        } else if voice.language.hasPrefix("en-") {
            score += 70
        }

        switch voice.quality {
        case .premium:
            score += 90
        case .enhanced:
            score += 60
        default:
            score += 15
        }

        let friendlyNames = ["Samantha", "Nicky", "Ava", "Allison", "Susan", "Karen", "Daniel", "Serena"]
        if friendlyNames.contains(where: { voice.name.localizedCaseInsensitiveContains($0) }) {
            score += 18
        }

        if voice.name.localizedCaseInsensitiveContains("compact") {
            score -= 35
        }

        return score
    }

    private func ssmlText(
        from text: String,
        voiceProfile: VoiceProfile,
        selectedVoice: AVSpeechSynthesisVoice?
    ) -> String {
        let ratePercent = Int((naturalRate(from: voiceProfile.rate) / 0.42) * 100)
        let pitchPercent = Int((naturalPitch(from: voiceProfile.pitch) - 1.0) * 70)
        let volume = voiceProfile.volume >= 0.95 ? "loud" : "medium"
        let escapedText = escapeSSML(text)
        let voiceAttributes = selectedVoice.map { #" xml:lang="\#($0.language)""# } ?? #" xml:lang="en-US""#

        return """
        <speak>
          <prosody\(voiceAttributes) rate="\(min(max(ratePercent, 84), 104))%" pitch="\(min(max(pitchPercent, -4), 10))%" volume="\(volume)">\(escapedText)</prosody>
        </speak>
        """
    }

    private func escapeSSML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func naturalRate(from directedRate: Float) -> Float {
        min(max(directedRate, 0.36), 0.48)
    }

    private func naturalPitch(from directedPitch: Float) -> Float {
        min(max(directedPitch, 0.95), 1.16)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }
}
