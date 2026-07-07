import Foundation
import CryptoKit

struct ElevenLabsConfiguration {
    var apiKey: String
    var voiceID: String
    var modelID: String

    static func load() -> ElevenLabsConfiguration? {
        let info = Bundle.main.infoDictionary ?? [:]
        let apiKey = (info["ElevenLabsAPIKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let voiceID = (info["ElevenLabsVoiceID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelID = (info["ElevenLabsModelID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !apiKey.isEmpty,
              !apiKey.contains("$("),
              !voiceID.isEmpty,
              !voiceID.contains("$(") else {
            return nil
        }

        return ElevenLabsConfiguration(
            apiKey: apiKey,
            voiceID: voiceID,
            modelID: modelID.isEmpty || modelID.contains("$(") ? "eleven_flash_v2_5" : modelID
        )
    }
}

struct ElevenLabsSpeechClient {
    enum ElevenLabsSpeechClientError: LocalizedError {
        case invalidURL
        case badStatus(Int, String)
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "ElevenLabs URL could not be created."
            case let .badStatus(statusCode, message):
                return "ElevenLabs returned \(statusCode): \(message)"
            case .emptyAudio:
                return "ElevenLabs returned empty audio."
            }
        }
    }

    private var configuration: ElevenLabsConfiguration
    private let cache = ElevenLabsSpeechCache()

    init(configuration: ElevenLabsConfiguration) {
        self.configuration = configuration
    }

    func speechData(for text: String, voiceProfile: VoiceProfile) async throws -> Data {
        let voiceID = selectedVoiceID(for: voiceProfile)
        let cacheKey = cache.key(
            text: text,
            voiceID: voiceID,
            modelID: configuration.modelID,
            voiceProfile: voiceProfile
        )
        if let cachedData = cache.data(for: cacheKey) {
            return cachedData
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.elevenlabs.io"
        components.path = "/v1/text-to-speech/\(voiceID)"
        components.queryItems = [
            URLQueryItem(name: "output_format", value: "mp3_44100_64"),
            URLQueryItem(name: "optimize_streaming_latency", value: "2")
        ]

        guard let url = components.url else {
            throw ElevenLabsSpeechClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(configuration.apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ElevenLabsSpeechRequest(
                text: text,
                modelID: configuration.modelID,
                voiceSettings: ElevenLabsVoiceSettings(voiceProfile: voiceProfile)
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsSpeechClientError.badStatus(-1, "No HTTP response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No error body."
            throw ElevenLabsSpeechClientError.badStatus(httpResponse.statusCode, message)
        }

        guard !data.isEmpty else {
            throw ElevenLabsSpeechClientError.emptyAudio
        }

        cache.store(data, for: cacheKey)
        return data
    }

    private func selectedVoiceID(for voiceProfile: VoiceProfile) -> String {
        guard let voiceIdentifier = voiceProfile.voiceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !voiceIdentifier.isEmpty,
              !voiceIdentifier.contains("$("),
              !voiceIdentifier.hasPrefix("com.apple.") else {
            return configuration.voiceID
        }

        return voiceIdentifier
    }
}

private struct ElevenLabsSpeechCache {
    private var directoryURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ElevenLabsSpeech", isDirectory: true)
    }

    func key(text: String, voiceID: String, modelID: String, voiceProfile: VoiceProfile) -> String {
        let rawKey = [
            voiceID,
            modelID,
            String(format: "%.2f", voiceProfile.rate),
            String(format: "%.2f", voiceProfile.pitch),
            String(format: "%.2f", voiceProfile.volume),
            text
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func data(for key: String) -> Data? {
        guard let fileURL = fileURL(for: key) else {
            return nil
        }

        return try? Data(contentsOf: fileURL)
    }

    func store(_ data: Data, for key: String) {
        guard let fileURL = fileURL(for: key),
              let directoryURL else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Cache failures should never block speech playback.
        }
    }

    private func fileURL(for key: String) -> URL? {
        directoryURL?.appendingPathComponent("\(key).mp3")
    }
}

private struct ElevenLabsSpeechRequest: Encodable {
    var text: String
    var modelID: String
    var voiceSettings: ElevenLabsVoiceSettings

    enum CodingKeys: String, CodingKey {
        case text
        case modelID = "model_id"
        case voiceSettings = "voice_settings"
    }
}

private struct ElevenLabsVoiceSettings: Encodable {
    var stability: Float
    var similarityBoost: Float
    var useSpeakerBoost: Bool

    init(voiceProfile: VoiceProfile) {
        let expressive = voiceProfile.pitch > 1.1 || voiceProfile.rate > 0.44
        stability = expressive ? 0.42 : 0.55
        similarityBoost = 0.78
        useSpeakerBoost = true
    }

    enum CodingKeys: String, CodingKey {
        case stability
        case similarityBoost = "similarity_boost"
        case useSpeakerBoost = "use_speaker_boost"
    }
}
