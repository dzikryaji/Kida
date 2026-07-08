import Foundation
import AVFoundation

/// ElevenLabs text-to-speech for the talking object. The voice is picked by the object's
/// (deterministic) gender + the current emotion — so an object always sounds the same, and its
/// mood matches the face. API key is read from `Info.plist["ElevenLabsAPIKey"]` (set it in
/// Secrets.xcconfig). No key → `speak` is a silent no-op, so the rest of the flow still works.
@MainActor
final class ObjectVoice {
    private var player: AVAudioPlayer?

    private enum Gender { case man, woman }

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

    private var apiKey: String {
        (Bundle.main.infoDictionary?["ElevenLabsAPIKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Speaks `text` in the object's voice. Gender is stable per `objectLabel` (a launch-stable
    /// hash), so the same object keeps one voice; the emotion picks happy/angry/sad.
    func speak(_ text: String, emotion: Emotion, objectLabel: String) async {
        let key = apiKey
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("$("), !body.isEmpty else { return }

        // Launch-stable hash (String.hashValue is randomized per process) → consistent gender.
        let seed = objectLabel.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let table = (seed % 2 == 0) ? Self.woman : Self.man
        let voiceID = table[emotion.voiceKey] ?? table["happy"] ?? ""
        guard !voiceID.isEmpty,
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": body,
            "model_id": "eleven_multilingual_v2",
            "voice_settings": ["stability": 0.45, "similarity_boost": 0.8],
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(data: data)
            player?.play()
        } catch {
            // Network/decode failure → stay silent; the on-screen bubble already showed the text.
        }
    }
}
