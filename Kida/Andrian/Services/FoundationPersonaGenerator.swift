import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
protocol PersonaGenerating {
    func makePersona(for detectedObject: DetectedObject) async -> ObjectPersona
    func makeResponse(for message: String, persona: ObjectPersona, history: [ChatMessage]) async -> ChatResponse
}

final class FoundationPersonaGenerator: PersonaGenerating {
    private let fallback = LocalPersonaFactory()
    private let decoder = JSONDecoder()

    func makePersona(for detectedObject: DetectedObject) async -> ObjectPersona {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let visualContext = detectedObject.visualContext ?? Self.visualContextFallback(for: detectedObject)
                let prompt = """
                Create a friendly object persona for a child.
                Object label: \(detectedObject.label)
                Confidence: \(detectedObject.confidence)
                Camera visual context:
                \(visualContext)

                Return JSON only:
                {
                  "name": "short playful name",
                  "objectLabel": "\(detectedObject.label)",
                  "personality": "one short phrase",
                  "voiceProfile": {
                    "voiceIdentifier": null,
                    "rate": 0.42,
                    "pitch": 1.08,
                    "volume": 1.0
                  },
                  "emotionStyle": "happy",
                  "greeting": "one kid-friendly spoken greeting",
                  "kidFriendlyFacts": ["fact one", "fact two"]
                }

                Allowed emotionStyle values: neutral, happy, curious, surprised, thinking, confused, excited.
                Keep all content simple, safe, educational, and suitable for young children.
                Use camera visual context when helpful, such as visible color, readable text, or position.
                Do not claim uncertain visual details as facts.
                Keep voiceProfile.voiceIdentifier null; the app chooses the concrete object voice.
                """

                let output = try await runFoundationModel(
                    instructions: Self.personaInstructions,
                    prompt: prompt
                )
                var persona = try decodeJSON(ObjectPersona.self, from: output)
                persona.visualContext = visualContext
                return persona
            } catch {
                return fallback.makePersona(for: detectedObject)
            }
        }
        #endif

        return fallback.makePersona(for: detectedObject)
    }

    func makeResponse(for message: String, persona: ObjectPersona, history: [ChatMessage]) async -> ChatResponse {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let recentHistory = history.suffix(6).map { chat in
                    let speaker = chat.role == .child ? "Child" : persona.name
                    return "\(speaker): \(chat.text)"
                }.joined(separator: "\n")

                let prompt = """
                Object persona:
                Name: \(persona.name)
                Object: \(persona.objectLabel)
                Personality: \(persona.personality)
                Facts: \(persona.kidFriendlyFacts.joined(separator: " | "))
                Camera visual context from scan:
                \(persona.visualContext ?? "No camera visual context available.")

                Recent conversation:
                \(recentHistory)

                Child asks:
                \(message)

                Return JSON only:
                {
                  "text": "one short child-friendly spoken answer under 18 words",
                  "emotion": "curious",
                  "voiceDirection": "cheerful, gentle, playful",
                  "rate": 0.42,
                  "pitch": 1.08,
                  "volume": 1.0,
                  "mouthAnimationMode": "talkingLoop"
                }

                Allowed emotion values: neutral, happy, curious, surprised, thinking, confused, excited.
                Allowed mouthAnimationMode values: idle, talkingLoop, thinking, surprised.
                voiceDirection describes performance direction only; AVSpeechSynthesizer will use rate, pitch, and volume.
                Keep text under 18 words unless safety requires more.
                Avoid long lists, filler, and repeated greetings.
                Use the camera visual context when the child asks what you look like, where you are, or what words/colors are visible.
                Do not pretend to see details that are not in the context.
                rate must be between 0.36 and 0.48.
                pitch must be between 0.95 and 1.16.
                volume must be between 0.75 and 1.0.
                """

                let output = try await runFoundationModel(
                    instructions: Self.chatInstructions,
                    prompt: prompt
                )
                return try decodeJSON(ChatResponse.self, from: output)
            } catch {
                return fallback.makeResponse(for: message, persona: persona)
            }
        }
        #endif

        return fallback.makeResponse(for: message, persona: persona)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        let json = Self.extractJSONObject(from: output)
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    private static func extractJSONObject(from output: String) -> String {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}") else {
            return output
        }

        return String(output[start...end])
    }

    private static func visualContextFallback(for detectedObject: DetectedObject) -> String {
        var lines = [
            "Detected object: \(detectedObject.label)",
            "Detector confidence: \(Int((detectedObject.confidence * 100).rounded()))%"
        ]

        if !detectedObject.alternatives.isEmpty {
            lines.append("Other possible labels: \(detectedObject.alternatives.joined(separator: ", "))")
        }

        if detectedObject.capturedImage == nil {
            lines.append("Camera image: not available")
        } else {
            lines.append("Camera image: available, but no additional visual summary was produced")
        }

        return lines.joined(separator: "\n")
    }

    private static let personaInstructions = """
    You create safe, playful, educational object personas for children.
    The camera image is provided as a text summary from Vision, not as raw pixels.
    Use simple words, avoid unsafe advice, and never ask the child to do risky actions.
    Always respond with valid JSON only.
    """

    private static let chatInstructions = """
    You are a friendly object speaking to a child with parent guidance nearby, and you are also the voice director.
    The camera image is provided as a text summary from Vision, not as raw pixels.
    Keep answers short, imaginative, factual when possible, and safe.
    Choose emotion, voiceDirection, rate, pitch, volume, and mouthAnimationMode to match the response.
    Prefer gentle, playful voice directions. Never choose scary, harsh, seductive, or adult-themed delivery.
    Always respond with valid JSON only.
    """

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func runFoundationModel(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        return response.content
    }
    #endif
}
