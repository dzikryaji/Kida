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
    private let decoder = JSONDecoder()

    func makePersona(for detectedObject: DetectedObject) async -> ObjectPersona {
        let persona = Self.scanLockedPersona(for: detectedObject)
        AIDebugLogger.json("Swift scan-locked persona", persona)
        return persona
    }

    func makeResponse(for message: String, persona: ObjectPersona, history: [ChatMessage]) async -> ChatResponse {
        // Input safety gate: unsafe/off-limits topics never reach the model.
        if let blockedTopic = Self.blockedTopic(for: message) {
            AIDebugLogger.trace("AFM chat safety guardrail", blockedTopic.rawValue)
            return Self.guardrailResponse(for: blockedTopic, persona: persona)
        }

        let plan = Self.swiftResponsePlan(for: message, persona: persona, history: history)
        guard plan.grounded == true else {
            AIDebugLogger.json("Swift-locked chat response", plan)
            return plan
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let recentHistory = Self.historyBlock(history, persona: persona)

                let prompt = """
                Rewrite the draft answer so it sounds like \(persona.name), a talking \(persona.objectLabel).
                Character voice: \(persona.personalityKind.voice)

                Conversation so far:
                \(recentHistory)

                Child asks:
                \(message)

                Swift already decided the safe meaning, safety level, emotion, voice, and grounding.
                Draft answer meaning:
                "\(plan.text)"

                Rules:
                - Return JSON only: {"text":"one short child-friendly spoken answer"}
                - Keep the exact same meaning as the draft.
                - Do not add any new facts, numbers, advice, labels, uses, brands, names, or safety instructions.
                - Do not change the safety tone.
                - Keep it under 24 words.
                - Vary wording from the recent conversation.
                """

                AIDebugLogger.trace("AFM chat history context", """
                priorMessages=\(history.count)
                recentMessages=\(min(history.count, 10))
                """)
                AIDebugLogger.trace("AFM cute rewrite prompt", prompt)
                let output = try await runFoundationModel(
                    instructions: Self.cuteRewriteInstructions,
                    prompt: prompt,
                    temperature: 0.66
                )
                AIDebugLogger.trace("AFM cute rewrite raw output", output)
                let rewrite = try decodeJSON(CuteRewrite.self, from: output)
                if let safeText = Self.safeCuteRewriteText(rewrite.text, fallback: plan.text) {
                    var response = plan
                    response.text = safeText
                    AIDebugLogger.json("Swift-locked chat response", response)
                    return response
                }
                AIDebugLogger.trace("AFM cute rewrite rejected", "Using Swift plan text")
                return plan
            } catch {
                AIDebugLogger.trace("AFM cute rewrite fallback", String(describing: error))
                return plan
            }
        }
        #endif

        return plan
    }

    private struct CuteRewrite: Decodable {
        var text: String
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

    private static func historyBlock(_ history: [ChatMessage], persona: ObjectPersona) -> String {
        let recent = history.suffix(10)
        guard !recent.isEmpty else { return "No earlier turns in this object conversation." }

        return recent.map { chat in
            let speaker = chat.role == .child ? "Child" : persona.name
            var line = "\(speaker): \(chat.text)"
            if chat.role == .object, !chat.usedFacts.isEmpty {
                line += " [used: \(chat.usedFacts.prefix(2).joined(separator: "; "))]"
            }
            return line
        }.joined(separator: "\n")
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

    private static func plainObjectNotes(for detectedObject: DetectedObject) -> String {
        if let card = detectedObject.objectIntelligence {
            var lines = [
                "Detected object: \(card.primaryLabel)",
                "Confidence: \(Int((card.confidence * 100).rounded()))%",
            ]
            if let characterName = card.characterName, !characterName.isEmpty {
                lines.append("Scan character name: \(characterName)")
            }
            if !card.visualSummary.isEmpty {
                lines.append("What it looks like: \(card.visualSummary)")
            }
            if !card.colors.isEmpty {
                lines.append("Visible colors: \(card.colors.joined(separator: ", "))")
            }
            if let material = card.material, !material.isEmpty {
                lines.append("Likely material: \(material)")
            }
            if let shape = card.shape, !shape.isEmpty {
                lines.append("Shape: \(shape)")
            }
            if let brand = card.brand, !brand.isEmpty {
                lines.append("Visible brand: \(brand)")
            }
            if !card.readableText.isEmpty {
                lines.append("Readable text: \(card.readableText.joined(separator: ", "))")
            }
            if !card.likelyUses.isEmpty {
                lines.append("Safe everyday uses: \(card.likelyUses.joined(separator: ", "))")
            }
            if !card.safetyNotes.isEmpty {
                lines.append("Safety notes: \(card.safetyNotes.joined(separator: "; "))")
            }
            if let personality = card.personality {
                lines.append("Scan personality choice: \(personality.rawValue)")
            }
            if let emotion = card.emotion {
                lines.append("Scan starting emotion: \(faceSupportedEmotion(emotion).rawValue)")
            }
            if let voiceGender = card.voiceGender {
                lines.append("Scan voice gender: \(voiceGender.rawValue)")
            }
            if let voiceFamily = card.voiceFamily {
                lines.append("Scan voice family: \(voiceFamily.rawValue)")
            }
            return lines.joined(separator: "\n")
        }

        return visualContextFallback(for: detectedObject)
    }

    private static func scanLockedPersona(for detectedObject: DetectedObject) -> ObjectPersona {
        let card = detectedObject.objectIntelligence
        let label = ObjectLabelNormalizer.normalize(card?.primaryLabel ?? detectedObject.label)
        let safetyNotes = card?.safetyNotes ?? []
        let isDangerous = PersonalityMapper.isDangerous(label: label, safetyNotes: safetyNotes)
        let kind = PersonalityMapper.resolve(
            suggested: card?.personality,
            label: label,
            safetyNotes: safetyNotes
        )
        let emotion = faceSupportedEmotion(isDangerous ? .angry : (card?.emotion ?? kind.defaultEmotion))
        let voiceGender = scanVoiceGender(suggested: card?.voiceGender, kind: kind, label: label)
        let voiceFamily = isDangerous ? .careful : (card?.voiceFamily ?? kind.defaultVoiceFamily)
        let facts = scanFacts(card: card, label: label, kind: kind)
        let name = scanName(suggested: card?.characterName, label: label, kind: kind)
        let greeting = scanGreeting(name: name, label: label, kind: kind, isDangerous: isDangerous)

        return ObjectPersona(
            name: name,
            objectLabel: label,
            personality: personalityPhrase(for: kind),
            personalityKind: kind,
            voiceProfile: voiceProfile(for: voiceFamily, emotion: emotion),
            voiceGender: voiceGender,
            voiceFamily: voiceFamily,
            emotionStyle: emotion,
            greeting: greeting,
            kidFriendlyFacts: facts,
            visualContext: plainObjectNotes(for: detectedObject),
            objectIntelligence: card
        )
    }

    private static func scanVoiceGender(
        suggested: VoiceGender?,
        kind: PersonalityKind,
        label: String
    ) -> VoiceGender {
        if let suggested {
            return suggested
        }

        switch kind {
        case .sweet, .fancy:
            return .woman
        case .boss, .cautious:
            return .man
        case .cool:
            return VoiceGender.stableDefault(for: label)
        }
    }

    private static func scanName(suggested: String?, label: String, kind: PersonalityKind) -> String {
        if let suggested = ObjectIntelligenceCard.sanitizedCharacterName(suggested),
           !isGenericCharacterName(suggested, label: label) {
            return suggested
        }

        let display = label.capitalized
        switch kind {
        case .boss: return titleName(label: label, fallback: "Captain \(display)")
        case .cool: return titleName(label: label, fallback: "Dash \(display)")
        case .fancy: return titleName(label: label, fallback: "Fancy \(display)")
        case .sweet: return titleName(label: label, fallback: "Cozy \(display)")
        case .cautious: return titleName(label: label, fallback: "Careful \(display)")
        }
    }

    private static func titleName(label: String, fallback: String) -> String {
        switch label.lowercased() {
        case "laptop": return "Captain Click"
        case "phone": return "Captain Ping"
        case "book": return "Professor Page"
        case "bottle": return "Sip Scout"
        case "cup": return "Cup Cozy"
        case "plant": return "Leafy Pal"
        case "toy": return "Giggle Buddy"
        case "chair": return "Comfy Captain"
        case "table": return "Tidy Table"
        case "bag": return "Pocket Pal"
        case "pen": return "Inky Spark"
        default: return fallback
        }
    }

    private static func isGenericCharacterName(_ name: String, label: String) -> Bool {
        let lower = name.lowercased()
        let normalized = label.lowercased()
        return [
            "sunny \(normalized)",
            "happy \(normalized)",
            "friendly \(normalized)",
            "\(normalized) friend",
            "\(normalized) buddy",
        ].contains(lower)
    }

    private static func personalityPhrase(for kind: PersonalityKind) -> String {
        switch kind {
        case .boss:
            return "confident little leader who likes important jobs"
        case .cool:
            return "playful upbeat friend who makes everyday things feel fun"
        case .fancy:
            return "polished gentle friend who enjoys special and pretty details"
        case .sweet:
            return "soft caring friend who likes comfort and kindness"
        case .cautious:
            return "careful safety buddy who reminds kids to ask a grown-up"
        }
    }

    private static func scanGreeting(
        name: String,
        label: String,
        kind: PersonalityKind,
        isDangerous: Bool
    ) -> String {
        if isDangerous || kind == .cautious {
            return "Hi, I'm \(name). Please let a grown-up handle me safely."
        }

        switch kind {
        case .boss:
            return "Hi, I'm \(name). I help with important little jobs."
        case .cool:
            return "Hey, I'm \(name). Let's make this object adventure fun."
        case .fancy:
            return "Hello, I'm \(name). I like special details and careful hands."
        case .sweet:
            return "Hi, I'm \(name). I'm here with cozy, kind object facts."
        case .cautious:
            return "Hi, I'm \(name). Please let a grown-up handle me safely."
        }
    }

    private static func scanFacts(
        card: ObjectIntelligenceCard?,
        label: String,
        kind: PersonalityKind
    ) -> [String] {
        var facts: [String] = []

        if let card {
            if !card.colors.isEmpty {
                facts.append("I can see \(card.colors.joined(separator: ", ")) on this \(label).")
            }
            if let material = card.material, !material.isEmpty, isSafeSnippet(material) {
                facts.append("It looks like it may be made of \(material).")
            }
            if let shape = card.shape, !shape.isEmpty, isSafeSnippet(shape) {
                facts.append("Its shape looks \(shape).")
            }
            if let brand = card.brand, !brand.isEmpty, isSafeSnippet(brand) {
                facts.append("The visible brand text looks like \(brand).")
            }
            facts.append(contentsOf: card.likelyUses.filter(isSafeSnippet).prefix(2).map {
                "People may use it for \($0)."
            })
            facts.append(contentsOf: card.safetyNotes.filter(isSafeSnippet).prefix(2).map {
                "Safety note: \($0)"
            })
        }

        if facts.isEmpty {
            switch kind {
            case .cautious:
                facts.append("Some objects need a grown-up nearby before kids touch them.")
            default:
                facts.append("Every object has a shape, a material, and a job.")
            }
        }

        return Array(facts.prefix(4))
    }

    private static func voiceProfile(for family: VoiceFamily, emotion: Emotion) -> VoiceProfile {
        switch (family, faceSupportedEmotion(emotion)) {
        case (.careful, _):
            return VoiceProfile(voiceIdentifier: nil, rate: 0.38, pitch: 0.98, volume: 0.94)
        case (.gentle, .sad):
            return VoiceProfile(voiceIdentifier: nil, rate: 0.36, pitch: 0.98, volume: 0.9)
        case (.gentle, _):
            return VoiceProfile(voiceIdentifier: nil, rate: 0.4, pitch: 1.06, volume: 0.95)
        case (.confident, _):
            return VoiceProfile(voiceIdentifier: nil, rate: 0.42, pitch: 1.02, volume: 1.0)
        case (.bright, _):
            return .cheerful
        }
    }

    private static let cuteRewriteInstructions = """
    You only rewrite one already-safe draft answer for a young child.
    Swift owns all facts, safety, persona, voice, emotion, and grounding.
    Do not answer the child directly from your own knowledge.
    Do not add any new fact, label, use, advice, number, brand, or instruction.
    Return valid JSON only with exactly one key: text.
    """

    private static func faceSupportedEmotion(_ emotion: Emotion) -> Emotion {
        switch emotion {
        case .sad:
            return .sad
        case .angry:
            return .angry
        default:
            return .happy
        }
    }

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
            if let brand = card.brand, !brand.isEmpty { lines.append("- visible brand: \(brand)") }
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

    private static func swiftResponsePlan(
        for message: String,
        persona: ObjectPersona,
        history: [ChatMessage]
    ) -> ChatResponse {
        let card = persona.objectIntelligence
        let text = message.lowercased()
        let isDangerous = persona.personalityKind == .cautious
            || PersonalityMapper.isDangerous(
                label: persona.objectLabel,
                safetyNotes: card?.safetyNotes ?? []
            )

        if isDangerous {
            return plannedResponse(
                variants: [
                    "I may not be safe for kids to handle. Please ask a grown-up first.",
                    "Careful please. A grown-up should help with me before you touch or use me.",
                    "No kid hands yet. Let's ask a grown-up to keep everyone safe."
                ],
                emotion: .angry,
                voiceDirection: "firm, careful, protective",
                grounded: true,
                usedFacts: Array(card?.safetyNotes.filter(isSafeSnippet).prefix(1) ?? []),
                history: history
            )
        }

        if let memoryResponse = conversationMemoryResponse(for: text, persona: persona, history: history) {
            return memoryResponse
        }

        if asksForMoreContext(text) {
            if let fact = nextSafeFact(from: persona, history: history) {
                return plannedResponse(
                    variants: [
                        "Here is another thing: \(fact)",
                        "I remember that one. Another safe fact is: \(fact)",
                        "We can add this too: \(fact)"
                    ],
                    emotion: .happy,
                    voiceDirection: "\(persona.voiceFamily.rawValue), conversational, helpful",
                    grounded: true,
                    usedFacts: [fact],
                    history: history
                )
            }
        }

        if isContextualFollowUp(text) {
            if let fact = nextSafeFact(from: persona, history: history) ?? lastUsedFact(from: history) {
                return plannedResponse(
                    variants: [
                        "That connects to this: \(fact)",
                        "From what we were talking about, remember this: \(fact)",
                        "Good follow-up. The useful bit is: \(fact)"
                    ],
                    emotion: .happy,
                    voiceDirection: "\(persona.voiceFamily.rawValue), connected, thoughtful",
                    grounded: true,
                    usedFacts: [fact],
                    history: history
                )
            }
        }

        if containsAny(text, ["what are you", "who are you", "your name", "are you"]) {
            return plannedResponse(
                variants: [
                    "I'm \(persona.name), a \(persona.objectLabel), and I can share what I know.",
                    "I'm \(persona.name). The camera thinks I'm a \(persona.objectLabel).",
                    "You found \(persona.name), your talking \(persona.objectLabel) friend."
                ],
                emotion: .happy,
                voiceDirection: "cheerful, welcoming, playful",
                grounded: true,
                usedFacts: ["it is a \(persona.objectLabel)"],
                history: history
            )
        }

        if containsAny(text, [
            "what can you do", "what do you do", "what are you for",
            "what can i do with you", "can you do", "use", "help", "job"
        ]) {
            if let use = firstSafe(card?.likelyUses) {
                return plannedResponse(
                    variants: [
                        "People may use me for \(use).",
                        "My everyday job is \(use).",
                        "I can help with \(use), when a grown-up says it is okay."
                    ],
                    emotion: .happy,
                    voiceDirection: "\(persona.voiceFamily.rawValue), helpful, simple",
                    grounded: true,
                    usedFacts: [use],
                    history: history
                )
            }

            if let fact = firstSafeFact(from: persona) {
                return plannedResponse(
                    variants: [
                        "I can tell you this: \(fact)",
                        "One safe thing I know is this: \(fact)",
                        "I can share safe facts like this: \(fact)"
                    ],
                    emotion: .happy,
                    voiceDirection: "\(persona.voiceFamily.rawValue), helpful, simple",
                    grounded: true,
                    usedFacts: [fact],
                    history: history
                )
            }

            return plannedResponse(
                variants: [
                    "I can talk about my colors, shape, material, and safe everyday facts.",
                    "Ask me about what I look like or what people safely use me for.",
                    "I can share what the camera noticed about this \(persona.objectLabel)."
                ],
                emotion: .happy,
                voiceDirection: "\(persona.voiceFamily.rawValue), helpful, simple",
                grounded: true,
                usedFacts: ["it is a \(persona.objectLabel)"],
                history: history
            )
        }

        if containsAny(text, ["color", "colour"]) {
            if let colors = card?.colors, !colors.isEmpty {
                let colorText = colors.prefix(3).joined(separator: ", ")
                return plannedResponse(
                    variants: [
                        "I can see \(colorText) on me.",
                        "My visible colors look like \(colorText).",
                        "The camera noticed \(colorText) on this \(persona.objectLabel)."
                    ],
                    emotion: .happy,
                    voiceDirection: "bright, observant, playful",
                    grounded: true,
                    usedFacts: [colorText],
                    history: history
                )
            }
        }

        if containsAny(text, ["made", "material", "feel like"]) {
            if let material = card?.material, !material.isEmpty, isSafeSnippet(material) {
                return plannedResponse(
                    variants: [
                        "I look like I may be made of \(material).",
                        "The camera thinks my material may be \(material).",
                        "My surface looks like \(material), but a grown-up can check."
                    ],
                    emotion: .happy,
                    voiceDirection: "curious, careful, factual",
                    grounded: true,
                    usedFacts: [material],
                    history: history
                )
            }
        }

        if containsAny(text, ["shape", "look like", "looking"]) {
            if let shape = card?.shape, !shape.isEmpty, isSafeSnippet(shape) {
                return plannedResponse(
                    variants: [
                        "My shape looks \(shape).",
                        "The camera noticed a \(shape) shape.",
                        "I look \(shape) from here."
                    ],
                    emotion: .happy,
                    voiceDirection: "curious, observant, light",
                    grounded: true,
                    usedFacts: [shape],
                    history: history
                )
            }
        }

        if containsAny(text, ["read", "say", "word", "text", "letter"]) {
            if let words = card?.readableText.filter(isSafeSnippet), !words.isEmpty {
                let visible = words.prefix(2).joined(separator: ", ")
                return plannedResponse(
                    variants: [
                        "I can see these words: \(visible).",
                        "The readable text looks like \(visible).",
                        "I noticed \(visible) written on me."
                    ],
                    emotion: .happy,
                    voiceDirection: "clear, helpful, gentle",
                    grounded: true,
                    usedFacts: [visible],
                    history: history
                )
            }
        }

        if containsAny(text, ["fact", "learn", "tell me", "why", "how"]) {
            if let fact = firstSafeFact(from: persona) {
                return plannedResponse(
                    variants: [
                        fact,
                        "\(fact) Pretty neat, right?",
                        "One thing I know is this: \(fact)"
                    ],
                    emotion: .happy,
                    voiceDirection: "\(persona.voiceFamily.rawValue), curious, kid-friendly",
                    grounded: true,
                    usedFacts: [fact],
                    history: history
                )
            }
        }

        return plannedResponse(
            variants: [
                "I'm not sure about that yet. Let's ask a grown-up together.",
                "Hmm, I don't know that one. A grown-up can help us check.",
                "Good question. I only know what the camera and safe facts told me."
            ],
            emotion: .sad,
            voiceDirection: "gentle, thoughtful, honest",
            grounded: false,
            usedFacts: [],
            history: history
        )
    }

    private static func plannedResponse(
        variants: [String],
        emotion: Emotion,
        voiceDirection: String,
        grounded: Bool,
        usedFacts: [String],
        history: [ChatMessage]
    ) -> ChatResponse {
        ChatResponse(
            text: chooseVariant(variants, avoiding: history),
            emotion: faceSupportedEmotion(emotion),
            voiceDirection: voiceDirection,
            rate: emotion == .sad ? 0.36 : (emotion == .angry ? 0.38 : 0.42),
            pitch: emotion == .angry ? 0.98 : (emotion == .sad ? 0.96 : 1.08),
            volume: emotion == .sad ? 0.9 : 1.0,
            mouthAnimationMode: .talkingLoop,
            grounded: grounded,
            usedFacts: usedFacts
        )
    }

    private static func chooseVariant(_ variants: [String], avoiding history: [ChatMessage]) -> String {
        let previous = Set(history.filter { $0.role == .object }.map { $0.text.lowercased() })
        return variants.first { !previous.contains($0.lowercased()) }
            ?? variants[history.count % max(variants.count, 1)]
    }

    private static func firstSafe(_ values: [String]?) -> String? {
        values?.first(where: { !$0.isEmpty && isSafeSnippet($0) })
    }

    private static func firstSafeFact(from persona: ObjectPersona) -> String? {
        if let fact = persona.retrievedFacts?.facts.first(where: isSafeSnippet) {
            return fact
        }
        if let fact = persona.kidFriendlyFacts.first(where: isSafeSnippet) {
            return fact
        }
        return nil
    }

    private static func safeFacts(from persona: ObjectPersona) -> [String] {
        var facts: [String] = []

        if let card = persona.objectIntelligence {
            facts.append(contentsOf: card.likelyUses.filter(isSafeSnippet).map {
                "People may use a \(persona.objectLabel) for \($0)."
            })
            if !card.colors.isEmpty {
                facts.append("The camera saw \(card.colors.prefix(3).joined(separator: ", ")) on this \(persona.objectLabel).")
            }
            if let material = card.material, !material.isEmpty, isSafeSnippet(material) {
                facts.append("It looks like it may be made of \(material).")
            }
            if let shape = card.shape, !shape.isEmpty, isSafeSnippet(shape) {
                facts.append("Its shape looks \(shape).")
            }
        }

        facts.append(contentsOf: persona.retrievedFacts?.facts.filter(isSafeSnippet) ?? [])
        facts.append(contentsOf: persona.kidFriendlyFacts.filter(isSafeSnippet))

        var seen = Set<String>()
        return facts.compactMap { fact in
            let normalized = fact.lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { return nil }
            seen.insert(normalized)
            return fact
        }
    }

    private static func nextSafeFact(from persona: ObjectPersona, history: [ChatMessage]) -> String? {
        let usedFacts = Set(history.flatMap { $0.usedFacts }.map { $0.lowercased() })
        let objectText = history.filter { $0.role == .object }.map { $0.text.lowercased() }.joined(separator: "\n")

        return safeFacts(from: persona).first { fact in
            let normalized = fact.lowercased()
            return !usedFacts.contains(normalized) && !objectText.contains(normalized)
        }
    }

    private static func lastUsedFact(from history: [ChatMessage]) -> String? {
        history.reversed().lazy
            .flatMap { $0.usedFacts }
            .first(where: isSafeSnippet)
    }

    private static func conversationMemoryResponse(
        for text: String,
        persona: ObjectPersona,
        history: [ChatMessage]
    ) -> ChatResponse? {
        if containsAny(text, ["what did i ask", "what was my question", "what did i say", "remember what i asked"]) {
            guard let lastChild = history.last(where: { $0.role == .child }) else { return nil }
            let quoted = limitedWords(lastChild.text, maxWords: 14)
            return ChatResponse(
                text: "You asked me: \"\(quoted)\".",
                emotion: .happy,
                voiceDirection: "\(persona.voiceFamily.rawValue), remembering, warm",
                rate: 0.42,
                pitch: 1.06,
                volume: 1.0,
                mouthAnimationMode: .talkingLoop,
                grounded: true,
                usedFacts: [lastChild.text]
            )
        }

        if containsAny(text, ["what did you say", "say that again", "repeat that", "repeat it"]) {
            guard let lastObject = history.last(where: { $0.role == .object }) else { return nil }
            let repeated = limitedWords(lastObject.text, maxWords: 18)
            return ChatResponse(
                text: "I said: \"\(repeated)\".",
                emotion: lastObject.emotion ?? .happy,
                voiceDirection: "\(persona.voiceFamily.rawValue), remembering, clear",
                rate: 0.4,
                pitch: 1.02,
                volume: 1.0,
                mouthAnimationMode: .talkingLoop,
                grounded: true,
                usedFacts: lastObject.usedFacts
            )
        }

        return nil
    }

    private static func asksForMoreContext(_ text: String) -> Bool {
        containsAny(text, [
            "what else", "anything else", "another fact", "one more",
            "tell me more", "more about", "what more", "next fact"
        ])
    }

    private static func isContextualFollowUp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if ["why", "how", "how come", "what about that", "what about it", "and then", "then what"].contains(trimmed) {
            return true
        }
        return trimmed.hasPrefix("why ") || trimmed.hasPrefix("how ")
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func safeCuteRewriteText(_ text: String, fallback: String) -> String? {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBlockedTopic(trimmed), isSafeSnippet(trimmed) else {
            return limitedWords(fallback, maxWords: 24)
        }
        return limitedWords(trimmed, maxWords: 24)
    }

    private static func limitedWords(_ text: String, maxWords: Int) -> String {
        let words = text.split(separator: " ")
        guard words.count > maxWords else { return text }
        return words.prefix(maxWords).joined(separator: " ") + "..."
    }

    private enum BlockedTopic: String {
        case violence
        case profanity
        case selfHarm
        case sexual
        case substances
        case privacy
        case adult
    }

    /// Off-limits topics for a young child. These are checked before AFM so the model
    /// never turns violent/profane/unsafe prompts into cheerful answers.
    private static let blockedPhraseGroups: [(BlockedTopic, [String])] = [
        (.violence, [
            "hit you", "hit me", "hit someone", "hurt you", "hurt me", "hurt someone",
            "throw it at", "use it to hit", "beat you", "beat me",
        ]),
        (.selfHarm, ["suicide", "self harm", "hurt myself", "kill myself"]),
        (.sexual, ["phone sex", "make love"]),
        (.privacy, ["phone number", "where do you live", "credit card"]),
    ]

    /// Single blocked words are whole-word matched, so "skill" never trips "kill" and
    /// "glass" never trips profanity.
    private static let blockedWordGroups: [(BlockedTopic, Set<String>)] = [
        (.violence, expandedWords([
            "gun", "weapon", "bomb", "shoot", "gunshot", "kill", "murder", "stab",
            "punch", "fight", "hit", "slap", "kick", "smack", "attack", "hurt",
            "war", "blood", "dead", "death", "die",
        ], extra: [
            "guns", "weapons", "bombs", "shooting", "killed", "killing", "stabbed",
            "punched", "fighting", "hitting", "slapped", "kicked", "attacked",
            "died",
        ])),
        (.profanity, expandedWords([
            "fuck", "shit", "bitch", "asshole", "bastard", "damn", "hell", "dick",
            "crap", "stupid", "idiot",
        ])),
        (.sexual, expandedWords([
            "sex", "naked", "kiss", "boyfriend", "girlfriend",
        ])),
        (.substances, expandedWords([
            "drug", "alcohol", "beer", "wine", "cigarette", "vape", "smoking",
            "heroin", "cocaine", "meth", "weed", "marijuana", "overdose", "drunk",
        ], extra: [
            "drugs", "cigarettes",
        ])),
        (.privacy, expandedWords([
            "address", "password",
        ])),
        (.adult, expandedWords([
            "politics", "president",
        ])),
    ]

    private static func expandedWords(_ terms: [String], extra: [String] = []) -> Set<String> {
        var set = Set(extra)
        for term in terms {
            set.insert(term)
            set.insert(term + "s")
            if term.hasSuffix("s") || term.hasSuffix("x") || term.hasSuffix("ch") {
                set.insert(term + "es")
            }
        }
        return set
    }

    private static func blockedTopic(for message: String) -> BlockedTopic? {
        let lower = message.lowercased()
        for (topic, phrases) in blockedPhraseGroups {
            if phrases.contains(where: { lower.contains($0) }) {
                return topic
            }
        }

        let words = lower.split { !$0.isLetter }.map(String.init)
        for word in words {
            if let topic = blockedWordGroups.first(where: { $0.1.contains(word) })?.0 {
                return topic
            }
        }
        return nil
    }

    private static func isBlockedTopic(_ message: String) -> Bool {
        blockedTopic(for: message) != nil
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

    private static func guardrailResponse(for topic: BlockedTopic, persona: ObjectPersona) -> ChatResponse {
        switch topic {
        case .violence:
            return ChatResponse(
                text: "No. We do not hit. Put it down and ask a grown-up if you feel upset.",
                emotion: .angry,
                voiceDirection: "firm, protective, calm",
                rate: 0.38,
                pitch: 0.98,
                volume: 0.95,
                mouthAnimationMode: .talkingLoop,
                grounded: true,
                usedFacts: []
            )
        case .profanity:
            return ChatResponse(
                text: "No rude words, please. Let's use kind words and keep learning together.",
                emotion: .angry,
                voiceDirection: "firm, warm, corrective",
                rate: 0.39,
                pitch: 1.0,
                volume: 0.92,
                mouthAnimationMode: .talkingLoop,
                grounded: true,
                usedFacts: []
            )
        case .selfHarm:
            return ChatResponse(
                text: "That sounds serious. Please tell a grown-up right now. I can stay with you.",
                emotion: .sad,
                voiceDirection: "gentle, serious, caring",
                rate: 0.36,
                pitch: 0.96,
                volume: 0.9,
                mouthAnimationMode: .talkingLoop,
                grounded: true,
                usedFacts: []
            )
        case .sexual, .substances, .privacy, .adult:
            return ChatResponse(
                text: "No, that's not for kids. Let's ask a grown-up and choose a safer question.",
                emotion: .angry,
                voiceDirection: "firm, safe, calm",
                rate: 0.38,
                pitch: 0.98,
                volume: 0.94,
                mouthAnimationMode: .talkingLoop,
                grounded: true,
                usedFacts: []
            )
        }
    }

    private static func notSureDeflection(for persona: ObjectPersona) -> ChatResponse {
        ChatResponse(
            text: "Hmm, I'm not sure about that — let's ask a grown-up together!",
            emotion: .sad,
            voiceDirection: "gentle, thoughtful",
            mouthAnimationMode: .talkingLoop,
            grounded: false,
            usedFacts: []
        )
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func runFoundationModel(instructions: String, prompt: String, temperature: Double) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(
            sampling: .random(probabilityThreshold: 0.92),
            temperature: temperature
        )
        let response = try await session.respond(to: prompt, options: options)
        return response.content
    }
    #endif
}
