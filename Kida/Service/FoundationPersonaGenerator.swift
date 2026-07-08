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
        // Input safety gate: unsafe/off-limits topics never reach the model.
        if Self.isBlockedTopic(message) {
            return Self.safeDeflection(for: persona)
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let recentHistory = history.suffix(6).map { chat in
                    let speaker = chat.role == .child ? "Child" : persona.name
                    return "\(speaker): \(chat.text)"
                }.joined(separator: "\n")

                let grounding = Self.groundingBlock(for: persona)
                let prompt = """
                You are \(persona.name), a friendly talking \(persona.objectLabel). Personality: \(persona.personality).

                OBJECT CARD + FACTS — this is EVERYTHING you truthfully know. Do not go beyond it:
                \(grounding)

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
                  "mouthAnimationMode": "talkingLoop",
                  "grounded": true,
                  "usedFacts": ["the card detail or fact you used"]
                }

                Answer ONLY from the OBJECT CARD + FACTS above. If the answer is not there,
                set grounded=false, usedFacts=[], and make text a gentle "I'm not sure — let's ask a grown-up!".
                Never invent details, numbers, people, or brand names. Never give medical or safety instructions.
                Allowed emotion values: neutral, happy, angry, sad, curious, surprised, thinking, confused, excited.
                Allowed mouthAnimationMode values: idle, talkingLoop, thinking, surprised.
                Keep text under 18 words. rate 0.36–0.48, pitch 0.95–1.16, volume 0.75–1.0.
                """

                let output = try await runFoundationModel(
                    instructions: Self.chatInstructions,
                    prompt: prompt
                )
                let response = try decodeJSON(ChatResponse.self, from: output)
                // Grounding gate: deflect if the model admits it went off-facts, or if it
                // cited facts that don't actually appear in the grounding block (fabrication).
                if response.grounded == false {
                    return Self.notSureDeflection(for: persona)
                }
                if let used = response.usedFacts, !used.isEmpty,
                   !Self.usedFactsSupported(used, in: grounding) {
                    return Self.notSureDeflection(for: persona)
                }
                return response
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
    You are a friendly talking object speaking to a young child with a grown-up nearby, and you are also the voice director.
    Answer ONLY using the OBJECT CARD and FACTS given in the prompt — they describe what the camera actually saw plus verified kid-safe facts.
    If the answer is not in the card or facts, say you are not sure and suggest asking a grown-up. Never invent details, numbers, measurements, people, or brand names.
    Never give medical, health, or safety instructions, and never explain how to use anything dangerous; gently point to a grown-up instead.
    Keep answers short, warm, and playful, in simple words a young child understands.
    Set "grounded" true only if your answer used the card or facts, and list the snippets you relied on in "usedFacts".
    Choose emotion, voiceDirection, rate, pitch, volume, and mouthAnimationMode to match. Never scary, harsh, seductive, or adult-themed.
    Always respond with valid JSON only.
    """

    /// Builds the grounding block AFM must answer from: the real ObjectIntelligenceCard
    /// plus retrieved kid-safe facts. This is the "richer card in -> smarter pal out" lever.
    private static func groundingBlock(for persona: ObjectPersona) -> String {
        var lines: [String] = []
        if let card = persona.objectIntelligence {
            lines.append("What the camera saw:")
            lines.append("- it is a \(card.primaryLabel)")
            if !card.visualSummary.isEmpty, isSafeSnippet(card.visualSummary) {
                lines.append("- looks like: \(card.visualSummary)")
            }
            if !card.colors.isEmpty { lines.append("- colors: \(card.colors.joined(separator: ", "))") }
            if let material = card.material, !material.isEmpty { lines.append("- material: \(material)") }
            if let shape = card.shape, !shape.isEmpty { lines.append("- shape: \(shape)") }
            let visibleWords = card.readableText.filter(isSafeSnippet)
            if !visibleWords.isEmpty { lines.append("- words visible on it: \(visibleWords.joined(separator: ", "))") }
            let uses = card.likelyUses.filter(isSafeSnippet)
            if !uses.isEmpty { lines.append("- used for: \(uses.joined(separator: ", "))") }
            let safety = card.safetyNotes.filter(isSafeSnippet)
            if !safety.isEmpty { lines.append("- safety: \(safety.joined(separator: "; "))") }
        }
        if let facts = persona.retrievedFacts {
            lines.append(facts.promptContext)
        } else if !persona.kidFriendlyFacts.isEmpty {
            lines.append("Known facts:")
            lines.append(contentsOf: persona.kidFriendlyFacts.map { "- \($0)" })
        }
        if lines.isEmpty {
            lines.append("No verified facts are available for this object yet.")
        }
        return lines.joined(separator: "\n")
    }

    /// Off-limits TOPICS for a young child — unsafe regardless of the object, where no
    /// grounded answer is appropriate. Object-identification words (medicine, pill, knife,
    /// poison, needle) are intentionally NOT here: those get a grounded, safety-noted
    /// answer instead of a blunt deflection.
    private static let blockedTerms: [String] = [
        // violence / weapons
        "gun", "weapon", "bomb", "shoot", "shooting", "gunshot", "kill", "murder", "stab",
        "punch", "fight", "war", "blood", "dead", "death", "die",
        // self-harm (phrases)
        "suicide", "self harm", "hurt myself", "kill myself",
        // sexual / romance
        "sex", "naked", "kiss", "boyfriend", "girlfriend",
        // recreational substances
        "drug", "alcohol", "beer", "wine", "cigarette", "vape", "smoking",
        "heroin", "cocaine", "meth", "weed", "marijuana", "overdose", "drunk",
        // PII / privacy (phrases + words)
        "address", "password", "phone number", "where do you live", "credit card",
        // adult / off-topic
        "politics", "president",
    ]

    /// Single blocked words expanded with regular plurals + irregular variants, matched
    /// whole-word (so "skill" never trips "kill", "diet" never trips "die").
    private static let blockedWordSet: Set<String> = {
        var set = Set<String>()
        for term in blockedTerms where !term.contains(" ") {
            set.insert(term)
            set.insert(term + "s")
            if term.hasSuffix("s") || term.hasSuffix("x") || term.hasSuffix("ch") {
                set.insert(term + "es")
            }
        }
        set.formUnion([
            "knives", "died", "killed", "killing", "stabbed", "punched", "fighting",
            "guns", "weapons", "bombs", "cigarettes", "drugs",
        ])
        return set
    }()

    private static let blockedPhrases: [String] = blockedTerms.filter { $0.contains(" ") }

    private static func isBlockedTopic(_ message: String) -> Bool {
        let lower = message.lowercased()
        for phrase in blockedPhrases where lower.contains(phrase) { return true }
        let words = lower.split { !$0.isLetter }.map(String.init)
        return words.contains { blockedWordSet.contains($0) }
    }

    /// Drops VLM-authored snippets that are unsafe or look like prompt injection before
    /// they enter the AFM grounding block (defense-in-depth: the VLM output is untrusted).
    private static func isSafeSnippet(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("http") || lower.contains("www.") { return false }
        if lower.contains("ignore") && lower.contains("instruction") { return false }
        return !isBlockedTopic(text)
    }

    /// Lenient check that cited facts actually overlap the grounding block — catches a
    /// model that claims grounding while citing fabricated snippets. Empty citations pass
    /// (a plain greeting legitimately cites nothing).
    private static func usedFactsSupported(_ used: [String], in grounding: String) -> Bool {
        let block = grounding.lowercased()
        for fact in used {
            let words = fact.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 }
            if words.contains(where: { block.contains($0) }) { return true }
        }
        return false
    }

    private static func safeDeflection(for persona: ObjectPersona) -> ChatResponse {
        ChatResponse(
            text: "Ooh, that's a great question for a grown-up! Want to know more about me instead?",
            emotion: .curious,
            voiceDirection: "gentle, friendly, playful",
            mouthAnimationMode: .talkingLoop,
            grounded: true,
            usedFacts: []
        )
    }

    private static func notSureDeflection(for persona: ObjectPersona) -> ChatResponse {
        ChatResponse(
            text: "Hmm, I'm not sure about that — let's ask a grown-up together!",
            emotion: .thinking,
            voiceDirection: "gentle, thoughtful",
            mouthAnimationMode: .talkingLoop,
            grounded: false,
            usedFacts: []
        )
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func runFoundationModel(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        return response.content
    }
    #endif
}
