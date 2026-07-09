import Foundation
import AVFoundation

/// ElevenLabs text-to-speech for the talking object. The concrete voice ID is locked from
/// the object's scan-time voice identity + starting emotion; later chat emotions change the
/// AR expression, not the character's voice identity. API key is read from
/// `Info.plist["ElevenLabsAPIKey"]` (set it in Secrets.xcconfig). No key → silent no-op.
@MainActor
final class ObjectVoice {
    struct PreparedSpeech {
        fileprivate let data: Data
        fileprivate let generation: Int
    }

    private var player: AVAudioPlayer?
    private var speakGeneration = 0

    // Emotion voices (happy / angry / sad) per gender — the provided ElevenLabs voice IDs.
    private static let woman: [String: String] = [
        "happy": "XfNU2rGpBa01ckF309OY",
        "angry": "yhFUAoS32gPDJFQHbH68",
        "sad":   "L0yTtpRXzdyzQlzALhgD",
    ]
    private static let man: [String: String] = [
        "happy": "TwDvT7Iy9phe6BzylUWu",
        "angry": "IjnA9kwZJHJ20Fp7Vmy6",
        "sad":   "GzE4TcXfh9rYCU9gVgPp",
    ]
    // Free-tier-safe fallback voices verified against ElevenLabs API. These keep audio working
    // when the preferred library voices return 402/payment_required for the current account.
    private static let fallbackWoman: [String: String] = [
        "happy": "EXAVITQu4vr4xnSDxMaL",
        "angry": "EXAVITQu4vr4xnSDxMaL",
        "sad":   "EXAVITQu4vr4xnSDxMaL",
    ]
    private static let fallbackMan: [String: String] = [
        "happy": "ErXwobaYiN019PkySvjV",
        "angry": "ErXwobaYiN019PkySvjV",
        "sad":   "ErXwobaYiN019PkySvjV",
    ]

    private var apiKey: String {
        (Bundle.main.infoDictionary?["ElevenLabsAPIKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func prepareSpeech(_ text: String, emotion: Emotion, persona: ObjectPersona) async -> PreparedSpeech? {
        await prepareSpeech(
            text,
            spokenEmotion: emotion,
            voiceIdentityEmotion: persona.emotionStyle,
            voiceGender: persona.voiceGender,
            voiceFamily: persona.voiceFamily
        )
    }

    func prepareSpeech(_ text: String, emotion: Emotion, objectLabel: String) async -> PreparedSpeech? {
        await prepareSpeech(
            text,
            spokenEmotion: emotion,
            voiceIdentityEmotion: emotion,
            voiceGender: VoiceGender.stableDefault(for: objectLabel),
            voiceFamily: .bright
        )
    }

    /// Speaks `text` in the object's stored scan-time voice identity. The current emotion
    /// is for performance/debug; the concrete voice ID stays locked to the scan result.
    @discardableResult
    func speak(_ text: String, emotion: Emotion, persona: ObjectPersona) async -> Bool {
        let prepared = await prepareSpeech(text, emotion: emotion, persona: persona)
        return play(prepared)
    }

    /// Fallback path for callers that do not yet have a persona. Gender remains stable per label.
    @discardableResult
    func speak(_ text: String, emotion: Emotion, objectLabel: String) async -> Bool {
        let prepared = await prepareSpeech(text, emotion: emotion, objectLabel: objectLabel)
        return play(prepared)
    }

    @discardableResult
    func play(_ preparedSpeech: PreparedSpeech?) -> Bool {
        guard let preparedSpeech else {
            AIDebugLogger.trace("TTS playback", "No prepared speech to play")
            return false
        }
        guard preparedSpeech.generation == speakGeneration else {
            AIDebugLogger.trace("TTS playback", "Prepared speech is stale")
            return false
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)

            let nextPlayer = try AVAudioPlayer(data: preparedSpeech.data)
            nextPlayer.volume = 1.0
            let didPrepare = nextPlayer.prepareToPlay()
            player = nextPlayer
            let didPlay = nextPlayer.play()
            AIDebugLogger.trace("TTS playback", """
            bytes=\(preparedSpeech.data.count)
            prepared=\(didPrepare)
            didPlay=\(didPlay)
            duration=\(String(format: "%.2f", nextPlayer.duration))
            """)
            return didPlay
        } catch {
            AIDebugLogger.trace("TTS error", String(describing: error))
            return false
        }
    }

    private func prepareSpeech(
        _ text: String,
        spokenEmotion: Emotion,
        voiceIdentityEmotion: Emotion,
        voiceGender: VoiceGender,
        voiceFamily: VoiceFamily
    ) async -> PreparedSpeech? {
        speakGeneration += 1
        let generation = speakGeneration
        player?.stop()
        player = nil

        let key = apiKey
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("$("), !body.isEmpty else {
            AIDebugLogger.trace("TTS skipped", "missingKey=\(key.isEmpty || key.contains("$(")) emptyText=\(body.isEmpty)")
            return nil
        }

        let preferredTable = voiceGender == .woman ? Self.woman : Self.man
        let fallbackTable = voiceGender == .woman ? Self.fallbackWoman : Self.fallbackMan
        let lockedVoiceKey = voiceIdentityEmotion.voiceKey
        let preferredID = preferredTable[lockedVoiceKey] ?? preferredTable["happy"] ?? ""
        let fallbackID = fallbackTable[lockedVoiceKey] ?? fallbackTable["happy"] ?? ""
        guard !preferredID.isEmpty else {
            AIDebugLogger.trace("TTS skipped", "No preferred voice for lockedVoiceKey=\(lockedVoiceKey)")
            return nil
        }

        do {
            AIDebugLogger.trace("TTS request", """
            spokenEmotion=\(spokenEmotion.voiceKey)
            lockedVoiceKey=\(lockedVoiceKey)
            gender=\(voiceGender.rawValue)
            family=\(voiceFamily.rawValue)
            textCharacters=\(body.count)
            apiKey=\(Self.apiKeySummary(key))
            """)

            var data = try await requestAudio(
                text: body,
                voiceID: preferredID,
                voiceFamily: voiceFamily,
                apiKey: key
            )
            guard generation == speakGeneration else {
                AIDebugLogger.trace("TTS skipped", "Stale preferred response ignored")
                return nil
            }
            if data == nil, fallbackID != preferredID {
                data = try await requestAudio(
                    text: body,
                    voiceID: fallbackID,
                    voiceFamily: voiceFamily,
                    apiKey: key
                )
                guard generation == speakGeneration else {
                    AIDebugLogger.trace("TTS skipped", "Stale fallback response ignored")
                    return nil
                }
            }
            guard let data else {
                AIDebugLogger.trace("TTS failed", "No audio data returned by preferred or fallback voice")
                return nil
            }
            return PreparedSpeech(data: data, generation: generation)
        } catch {
            AIDebugLogger.trace("TTS error", String(describing: error))
            return nil
        }
    }

    private func requestAudio(
        text: String,
        voiceID: String,
        voiceFamily: VoiceFamily,
        apiKey: String
    ) async throws -> Data? {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": "eleven_multilingual_v2",
            "voice_settings": Self.voiceSettings(for: voiceFamily),
        ])

        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            AIDebugLogger.trace("TTS HTTP", """
            voiceID=\(voiceID)
            status=\(status)
            bytes=\(data.count)
            body=\(Self.responseSummary(data))
            """)
            return nil
        }
        AIDebugLogger.trace("TTS HTTP", "voiceID=\(voiceID) status=\(http.statusCode) bytes=\(data.count)")
        return data
    }

    private static func voiceSettings(for family: VoiceFamily) -> [String: Double] {
        switch family {
        case .bright:
            return ["stability": 0.42, "similarity_boost": 0.8]
        case .gentle:
            return ["stability": 0.58, "similarity_boost": 0.82]
        case .confident:
            return ["stability": 0.48, "similarity_boost": 0.86]
        case .careful:
            return ["stability": 0.66, "similarity_boost": 0.84]
        }
    }

    private static func apiKeySummary(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        if trimmed.hasPrefix("sk_") {
            prefix = "sk_"
        } else if trimmed.hasPrefix("xi-") {
            prefix = "xi-"
        } else if trimmed.isEmpty {
            prefix = "empty"
        } else {
            prefix = "other"
        }
        return "length=\(trimmed.count) prefix=\(prefix)"
    }

    private static func responseSummary(_ data: Data) -> String {
        guard !data.isEmpty else { return "<empty>" }
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
