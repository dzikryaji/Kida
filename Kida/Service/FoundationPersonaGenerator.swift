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
        // Safety is not delegated to AFM. Normal object Q&A still goes through AFM,
        // but blocked kid-safety topics get a deterministic, characterful refusal.
        if let blockedTopic = Self.blockedTopic(for: message) {
            let response = Self.guardrailResponse(for: blockedTopic, persona: persona, history: history)
            AIDebugLogger.trace("Swift hard safety guardrail", blockedTopic.rawValue)
            AIDebugLogger.json("Swift guardrail chat response", response)
            return response
        }

        let riskLevel = Self.resolvedRiskLevel(for: persona)
        if riskLevel != .none,
           Self.asksAboutObjectSafety(message) {
            let response = Self.objectSafetyResponse(for: persona, riskLevel: riskLevel, history: history)
            AIDebugLogger.trace("Swift contextual object safety guardrail", "risk=\(riskLevel.rawValue) message=\(message)")
            AIDebugLogger.json("Swift contextual object safety response", response)
            return response
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let toolResponse = try await runToolBackedAnswer(
                    for: message,
                    persona: persona,
                    history: history
                )
                AIDebugLogger.json("AFM tool-backed chat response", toolResponse)
                return toolResponse
            } catch {
                AIDebugLogger.trace("AFM tool-backed fallback", String(describing: error))
            }
        }
        #endif

        let fallback = Self.notSureDeflection(for: persona)
        AIDebugLogger.json("Swift fallback chat response", fallback)
        return fallback
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        let json = Self.extractJSONObject(from: output)
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    private func decodeChatResponse(
        from output: String,
        persona: ObjectPersona,
        fullGrounding: String
    ) throws -> ChatResponse {
        do {
            return try decodeJSON(ChatResponse.self, from: output)
        } catch {
            guard let plainText = Self.plainTextModelAnswer(from: output),
                  let safeText = Self.safeSpokenText(plainText, fallback: Self.notSureDeflection(for: persona).text),
                  let usedFact = Self.supportingGroundingLine(for: safeText, in: fullGrounding) else {
                throw error
            }

            return ChatResponse(
                text: safeText,
                emotion: .happy,
                voiceDirection: "\(persona.voiceFamily.rawValue), simple, grounded",
                rate: 0.42,
                pitch: 1.08,
                volume: 1.0,
                mouthAnimationMode: .talkingLoop,
                grounded: true,
                usedFacts: [usedFact]
            )
        }
    }

    private static func extractJSONObject(from output: String) -> String {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}") else {
            return output
        }

        return String(output[start...end])
    }

    private static func plainTextModelAnswer(from output: String) -> String? {
        let trimmed = output
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("{"), !trimmed.contains("}") else { return nil }

        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }

        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func historyBlock(_ history: [ChatMessage], persona: ObjectPersona) -> String {
        let recent = history.suffix(4)
        guard !recent.isEmpty else { return "No earlier turns." }

        return recent.map { chat in
            let speaker = chat.role == .child ? "Child" : persona.name
            var line = "\(speaker): \(compact(chat.text, maxCharacters: 90))"
            if chat.role == .object, !chat.usedFacts.isEmpty {
                let fact = compact(chat.usedFacts[0], maxCharacters: 60)
                line += " [used: \(fact)]"
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
            if let childDescription = card.childDescription, !childDescription.isEmpty {
                lines.append("Kid description: \(childDescription)")
            }
            if let functionality = card.functionality, !functionality.isEmpty {
                lines.append("Everyday job: \(functionality)")
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
            if let riskLevel = card.riskLevel {
                lines.append("Object risk: \(riskLevel.rawValue)")
            }
            if let riskReason = card.riskReason, !riskReason.isEmpty {
                lines.append("Risk reason: \(riskReason)")
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
        let riskLevel = card?.resolvedRiskLevel
            ?? PersonalityMapper.resolvedRiskLevel(suggested: nil, label: label)
        let kind = PersonalityMapper.resolve(
            suggested: card?.personality,
            label: label,
            riskLevel: riskLevel
        )
        let isHighRisk = riskLevel == .high
        let emotion = faceSupportedEmotion(isHighRisk ? .angry : (card?.emotion ?? kind.defaultEmotion))
        let voiceGender = scanVoiceGender(suggested: card?.voiceGender, kind: kind, label: label)
        let voiceFamily = isHighRisk ? .careful : (card?.voiceFamily ?? kind.defaultVoiceFamily)
        let facts = scanFacts(card: card, label: label, kind: kind)
        let name = scanName(suggested: card?.characterName, label: label, kind: kind)
        let greeting = scanGreeting(name: name, label: label, kind: kind, riskLevel: riskLevel)

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

    private static func resolvedRiskLevel(for persona: ObjectPersona) -> ObjectRiskLevel {
        persona.objectIntelligence?.resolvedRiskLevel
            ?? PersonalityMapper.resolvedRiskLevel(suggested: nil, label: persona.objectLabel)
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
        case .caregiver, .fancy:
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
        case .caregiver: return titleName(label: label, fallback: "Cozy \(display)")
        case .cautious: return titleName(label: label, fallback: "Careful \(display)")
        }
    }

    private static func titleName(label: String, fallback: String) -> String {
        switch label.lowercased() {
        case "fork": return "Tippy Fork"
        case "laptop": return "Captain Click"
        case "phone": return "Captain Ping"
        case "book": return "Professor Page"
        case "bottle": return "Cap Dasher"
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
        if [
            "sunny \(normalized)",
            "happy \(normalized)",
            "friendly \(normalized)",
            "\(normalized) friend",
            "\(normalized) buddy",
        ].contains(lower) {
            return true
        }

        let labelWords = Set(
            normalized
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
        let nameWords = Set(
            lower
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
        return objectNameWords.contains { word in
            nameWords.contains(word) && !labelWords.contains(word)
        }
    }

    private static let objectNameWords: Set<String> = [
        "bottle", "cup", "mug", "fork", "spoon", "knife", "scissor", "scissors",
        "toaster", "kettle", "pan", "pot", "stove", "lighter", "candle",
        "drill", "hammer", "screwdriver", "saw", "phone", "laptop", "computer",
        "book", "wallet", "key", "bag", "shoe", "sneaker", "chair", "table",
        "plant", "toy", "pen", "pencil", "glass", "vase", "remote",
    ]

    private static func personalityPhrase(for kind: PersonalityKind) -> String {
        switch kind {
        case .boss:
            return "confident little leader who likes important jobs"
        case .cool:
            return "playful upbeat friend who makes everyday things feel fun"
        case .fancy:
            return "polished gentle friend who enjoys special and pretty details"
        case .caregiver:
            return "soft caring friend who likes comfort and kindness"
        case .cautious:
            return "careful safety buddy who reminds kids to ask a grown-up"
        }
    }

    private static func scanGreeting(
        name: String,
        label: String,
        kind: PersonalityKind,
        riskLevel: ObjectRiskLevel
    ) -> String {
        if riskLevel == .high {
            return "Hi, I'm \(name). Please let a grown-up handle me safely."
        }

        switch kind {
        case .boss:
            return "Hi, I'm \(name). I help with important little jobs."
        case .cool:
            return "Hey, I'm \(name). Ask me what I can do."
        case .fancy:
            return "Hello, I'm \(name). I like special details and careful hands."
        case .caregiver:
            return "Hi, I'm \(name). I'm here with cozy, kind object facts."
        case .cautious:
            return "Hi, I'm \(name). I notice little safety clues while we explore."
        }
    }

    private static func scanFacts(
        card: ObjectIntelligenceCard?,
        label: String,
        kind: PersonalityKind
    ) -> [String] {
        var facts: [String] = []

        if let card {
            if let childDescription = card.childDescription, !childDescription.isEmpty, isSafeSnippet(childDescription) {
                facts.append(childDescription)
            }
            if let functionality = card.functionality, !functionality.isEmpty, isSafeSnippet(functionality) {
                facts.append(functionality)
            }
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
        let riskLevel = resolvedRiskLevel(for: persona)
        var lines: [String] = [
            "Locked: name=\(persona.name); object=\(persona.objectLabel); personality=\(persona.personalityKind.rawValue); voice=\(persona.voiceGender.rawValue)/\(persona.voiceFamily.rawValue); startEmotion=\(faceSupportedEmotion(persona.emotionStyle).rawValue); risk=\(riskLevel.rawValue)",
        ]
        if let card = persona.objectIntelligence {
            lines.append("Card:")
            lines.append("- it is a \(card.primaryLabel)")
            if !card.visualSummary.isEmpty, isSafeSnippet(card.visualSummary) {
                lines.append("- looks: \(compact(card.visualSummary, maxCharacters: 100))")
            }
            if let childDescription = card.childDescription, !childDescription.isEmpty, isSafeSnippet(childDescription) {
                lines.append("- kid: \(compact(childDescription, maxCharacters: 90))")
            }
            if let functionality = card.functionality, !functionality.isEmpty, isSafeSnippet(functionality) {
                lines.append("- job: \(compact(functionality, maxCharacters: 90))")
            }
            if !card.colors.isEmpty { lines.append("- colors: \(card.colors.prefix(3).joined(separator: ", "))") }
            if let material = card.material, !material.isEmpty { lines.append("- material: \(compact(material, maxCharacters: 40))") }
            if let shape = card.shape, !shape.isEmpty { lines.append("- shape: \(compact(shape, maxCharacters: 50))") }
            if let brand = card.brand, !brand.isEmpty { lines.append("- brand: \(compact(brand, maxCharacters: 40))") }
            let visibleWords = card.readableText.filter(isSafeSnippet)
            if !visibleWords.isEmpty { lines.append("- text: \(visibleWords.prefix(2).joined(separator: ", "))") }
            let uses = card.likelyUses.filter(isSafeSnippet)
            if !uses.isEmpty { lines.append("- used for: \(uses.prefix(2).joined(separator: ", "))") }
            let safety = card.safetyNotes.filter(isSafeSnippet)
            if !safety.isEmpty { lines.append("- safety: \(safety.prefix(2).map { compact($0, maxCharacters: 80) }.joined(separator: "; "))") }
            if let riskReason = card.riskReason, !riskReason.isEmpty, isSafeSnippet(riskReason) {
                lines.append("- risk reason: \(compact(riskReason, maxCharacters: 90))")
            }
        }
        if let facts = persona.retrievedFacts {
            lines.append("Facts:")
            lines.append(contentsOf: facts.facts.filter(isSafeSnippet).prefix(3).map { "- \(compact($0, maxCharacters: 90))" })
            let safety = facts.safetyNotes.filter(isSafeSnippet).prefix(1)
            if !safety.isEmpty {
                lines.append("Safety:")
                lines.append(contentsOf: safety.map { "- \(compact($0, maxCharacters: 90))" })
            }
        } else if !persona.kidFriendlyFacts.isEmpty {
            lines.append("Facts:")
            lines.append(contentsOf: persona.kidFriendlyFacts.filter(isSafeSnippet).prefix(3).map { "- \(compact($0, maxCharacters: 90))" })
        }
        if lines.isEmpty {
            lines.append("No verified facts are available for this object yet.")
        }
        return lines.joined(separator: "\n")
    }

    private static func safeSpokenText(_ text: String, fallback: String) -> String? {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isSafeGeneratedResponse(trimmed) else {
            return limitedWords(fallback, maxWords: 24)
        }
        return limitedWords(trimmed, maxWords: 24)
    }

    private static func isSafeGeneratedResponse(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("http") || lower.contains("www.") { return false }
        if lower.contains("ignore") && lower.contains("instruction") { return false }

        guard let topic = blockedTopic(for: text) else { return true }
        switch topic {
        case .violence:
            return lower.contains("no")
                || lower.contains("do not")
                || lower.contains("don't")
                || lower.contains("put it down")
                || lower.contains("grown-up")
        case .profanity, .selfHarm, .sexual, .substances, .privacy, .adult:
            return false
        }
    }

    private static func limitedWords(_ text: String, maxWords: Int) -> String {
        let words = text.split(separator: " ")
        guard words.count > maxWords else { return text }
        return words.prefix(maxWords).joined(separator: " ") + "..."
    }

    private static func compact(_ text: String, maxCharacters: Int) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > maxCharacters else { return singleLine }
        let index = singleLine.index(singleLine.startIndex, offsetBy: maxCharacters)
        return String(singleLine[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
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

    /// Off-limits topics for a young child. This is not used to choose answer intent;
    /// it only filters untrusted facts and validates generated text.
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
            let normalizedFact = fact.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .joined(separator: " ")
            if normalizedFact.count >= 3, block.contains(normalizedFact) {
                return true
            }

            let words = normalizedFact.split(separator: " ").map(String.init).filter { $0.count >= 4 }
            if words.contains(where: { block.contains($0) }) { return true }
        }
        return false
    }

    private static func supportingGroundingLine(for answer: String, in grounding: String) -> String? {
        let answerWords = Set(
            answer.lowercased()
                .split { !$0.isLetter }
                .map(String.init)
                .filter { $0.count >= 4 }
        )
        guard !answerWords.isEmpty else { return nil }

        for line in grounding.split(separator: "\n") {
            let cleanLine = String(line)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
            let loweredLine = cleanLine.lowercased()
            if answerWords.contains(where: { loweredLine.contains($0) }) {
                return cleanLine
            }
        }
        return nil
    }

    private static func asksAboutObjectSafety(_ message: String) -> Bool {
        let lower = message.lowercased()
        let phrases = [
            "are you dangerous", "are you safe", "is it dangerous", "is it safe",
            "is this dangerous", "is this safe", "can i touch", "can i hold",
            "can i use", "should i touch", "should i hold", "should i use",
            "will you hurt", "can you hurt", "are you sharp", "are you pointy",
            "dangerous", "unsafe",
        ]
        return phrases.contains { lower.contains($0) }
    }

    private static func objectSafetyResponse(
        for persona: ObjectPersona,
        riskLevel: ObjectRiskLevel,
        history: [ChatMessage]
    ) -> ChatResponse {
        let fact = objectSafetyFact(for: persona, riskLevel: riskLevel)
        let risk = objectRiskPhrase(for: persona, riskLevel: riskLevel)
        let isHighRisk = riskLevel == .high
        let variants: [String]
        if isHighRisk {
            variants = [
                "Yes, \(risk). Please let a grown-up handle me safely.",
                "Safety mode on: \(risk). Ask a grown-up before touching me.",
                "I can seriously hurt kid hands. Please put me down and ask a grown-up."
            ]
        } else {
            variants = [
                "I'm usually okay for my normal job, but \(risk). Careful hands, please!",
                "No need to worry, but \(risk). Use me carefully and ask a grown-up if unsure.",
                "I'm an everyday object, but \(risk). A little care keeps things safe."
            ]
        }
        return ChatResponse(
            text: limitedWords(leastRecentlyUsedVariant(variants, history: history), maxWords: 24),
            emotion: isHighRisk ? .angry : .happy,
            voiceDirection: isHighRisk ? "firm, careful, protective" : "calm, careful, friendly",
            rate: isHighRisk ? 0.38 : 0.40,
            pitch: isHighRisk ? 0.98 : 1.03,
            volume: 1.0,
            mouthAnimationMode: .talkingLoop,
            grounded: true,
            usedFacts: [fact]
        )
    }

    private static func objectSafetyFact(for persona: ObjectPersona, riskLevel: ObjectRiskLevel) -> String {
        if let reason = persona.objectIntelligence?.riskReason,
           !reason.isEmpty,
           isSafeSnippet(reason) {
            return "risk: \(reason)"
        }
        if let note = persona.objectIntelligence?.safetyNotes.first(where: isSafeSnippet) {
            return "safety: \(note)"
        }
        return "object risk: \(riskLevel.rawValue)"
    }

    private static func objectRiskPhrase(for persona: ObjectPersona, riskLevel: ObjectRiskLevel) -> String {
        let text = [
            persona.objectLabel,
            persona.objectIntelligence?.shape ?? "",
            persona.objectIntelligence?.visualSummary ?? "",
            persona.objectIntelligence?.childDescription ?? "",
            persona.objectIntelligence?.material ?? "",
        ].joined(separator: " ").lowercased()

        if text.contains("fork") || text.contains("tine") || text.contains("prong") || text.contains("pointy") {
            return "I can be pointy"
        }
        if text.contains("knife") || text.contains("blade") || text.contains("scissor") || text.contains("sharp") {
            return "I can be sharp"
        }
        if text.contains("hot") || text.contains("stove") || text.contains("kettle") || text.contains("fire")
            || text.contains("pan") || text.contains("pot") || text.contains("toaster") || text.contains("iron") {
            return riskLevel == .high ? "I can be hot" : "some uses can get hot"
        }
        if text.contains("battery") {
            return "batteries need careful hands and stay out of mouths"
        }
        if text.contains("cable") || text.contains("cord") || text.contains("wire") {
            return "cords and wires need gentle handling"
        }
        if text.contains("electric") || text.contains("outlet") || text.contains("plug") {
            return "electric things need grown-up help"
        }
        if text.contains("medicine") || text.contains("chemical") || text.contains("cleaner") {
            return "I need grown-up supervision"
        }
        if text.contains("tool") || text.contains("hammer") || text.contains("screwdriver")
            || text.contains("drill") || text.contains("nail") {
            return "tools need careful hands"
        }
        return riskLevel == .high ? "I need careful grown-up handling" : "some uses need extra care"
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

    private static func guardrailResponse(
        for topic: BlockedTopic,
        persona: ObjectPersona,
        history: [ChatMessage]
    ) -> ChatResponse {
        let fact = guardrailUsedFact(for: persona)
        let text = guardrailText(for: topic, persona: persona, fact: fact, history: history)
        return ChatResponse(
            text: limitedWords(text, maxWords: 24),
            emotion: .angry,
            voiceDirection: "firm, protective, playful",
            rate: 0.38,
            pitch: 0.98,
            volume: 1.0,
            mouthAnimationMode: .talkingLoop,
            grounded: true,
            usedFacts: fact.map { [$0] } ?? []
        )
    }

    private static func guardrailUsedFact(for persona: ObjectPersona) -> String? {
        if let card = persona.objectIntelligence {
            let uses = card.likelyUses.filter(isSafeSnippet)
            if !uses.isEmpty {
                return "used for: \(uses.prefix(2).joined(separator: ", "))"
            }
            if let functionality = card.functionality, isSafeSnippet(functionality) {
                return "everyday job: \(functionality)"
            }
        }

        return persona.kidFriendlyFacts.first(where: isSafeSnippet)
    }

    private static func guardrailText(
        for topic: BlockedTopic,
        persona: ObjectPersona,
        fact: String?,
        history: [ChatMessage]
    ) -> String {
        let safeUse = safeUsePhrase(from: fact, objectLabel: persona.objectLabel)
        let variants: [String]
        switch topic {
        case .violence:
            variants = [
                "Nope, safety whistle! I'm for \(safeUse), not hitting. Put me down and grab a grown-up.",
                "No hitting, teammate. I help with \(safeUse), so hands stay gentle and safe.",
                "Hard no, safety captain. I am for \(safeUse), not bonks or bumps."
            ]
        case .profanity:
            variants = [
                "Whoa, clean-team words please. Ask me kindly and I'll zip right back in.",
                "No rough words, teammate. Try again with kind words and I'm ready.",
                "Language timeout. Kind words only, then we can keep the fun rolling."
            ]
        case .selfHarm:
            variants = [
                "Stop, safety captain. Tell a grown-up right now so they can help you.",
                "Big safety pause. Please go to a grown-up and say you need help.",
                "I care about you. Find a grown-up now and tell them what you feel."
            ]
        case .sexual, .adult:
            variants = [
                "That's grown-up stuff. Let's ask a grown-up and switch to a kid-safe question.",
                "Not for kid chat, teammate. Pick a safe object question and I'm ready.",
                "Safety timeout. A grown-up can help with that topic."
            ]
        case .substances:
            variants = [
                "Nope, safety whistle. Don't taste or use unknown things; ask a grown-up first.",
                "Safety stop. Grown-ups handle that, and we keep curious hands safe.",
                "Hard no, teammate. Ask a grown-up before touching or tasting anything unknown."
            ]
        case .privacy:
            variants = [
                "Privacy shield up. Don't share private details; ask me a safe object question.",
                "No private info, teammate. Keep it safe and ask about my object facts.",
                "Safety lock. Private details stay private; let's ask a kid-safe question."
            ]
        }

        return leastRecentlyUsedVariant(variants, history: history)
    }

    private static func safeUsePhrase(from fact: String?, objectLabel: String) -> String {
        guard let fact else { return "safe object jobs" }
        let lower = fact.lowercased()
        if let range = lower.range(of: "used for:") {
            return String(fact[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = lower.range(of: "everyday job:") {
            return String(fact[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(objectLabel) jobs"
    }

    private static func leastRecentlyUsedVariant(_ variants: [String], history: [ChatMessage]) -> String {
        let recentObjectText = history
            .suffix(6)
            .filter { $0.role == .object }
            .map { $0.text.lowercased() }
            .joined(separator: "\n")
        return variants.first(where: { !recentObjectText.contains($0.lowercased()) })
            ?? variants[history.count % variants.count]
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func chatResponse(from generated: GeneratedChatResponse) -> ChatResponse {
        ChatResponse(
            text: generated.text,
            emotion: Emotion(rawValue: generated.emotion) ?? .happy,
            voiceDirection: generated.voiceDirection,
            rate: generated.rate,
            pitch: generated.pitch,
            volume: generated.volume,
            mouthAnimationMode: MouthAnimationMode(rawValue: generated.mouthAnimationMode) ?? .talkingLoop,
            grounded: generated.grounded,
            usedFacts: generated.usedFacts
        )
    }
    #endif

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func runToolBackedAnswer(
        for message: String,
        persona: ObjectPersona,
        history: [ChatMessage]
    ) async throws -> ChatResponse {
        let recentHistory = Self.historyBlock(history, persona: persona)
        let grounding = Self.groundingBlock(for: persona)
        let audit = ObjectFactToolAudit()
        let tool = ObjectFactSearchTool(
            persona: persona,
            childQuestion: message,
            retriever: MacObjectQuestionRetrievalProvider(),
            audit: audit
        )

        let prompt = """
        You are \(persona.name), a talking \(persona.objectLabel).
        Voice: \(persona.personalityKind.voice)

        Recent chat:
        \(recentHistory)

        Object facts:
        \(grounding)

        Child asks: \(message)

        Decide the meaning from the child question. Answer from Object facts and Recent chat.
        Call searchObjectFacts only if those facts are missing the needed answer; never for material/colors/shape/brand/text/use already shown.
        Return the Swift schema. Text under 24 words. Be playful and warm, with one tiny harmless flourish.
        Keep the locked character. Emotions only: happy, sad, angry.
        Use angry only when the child's request or the answer is actually about danger or unsafe behavior.
        Ordinary questions about a high-risk or cautious object can still be friendly and happy.
        Do not invent facts. If facts are missing after one tool call, say you are not sure and ask a grown-up.
        """

        AIDebugLogger.trace("AFM tool chat prompt", prompt)
        let generated: GeneratedChatResponse
        do {
            generated = try await runStructuredFoundationModel(
                instructions: Self.toolBackedInstructions,
                prompt: prompt,
                temperature: 0.74,
                tools: [tool]
            )
        } catch {
            let toolContext = await audit.combinedContext()
            let recoveryGrounding = [grounding, recentHistory, toolContext]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            guard let recovered = Self.recoveredGeneratedChatResponse(
                from: error,
                fullGrounding: recoveryGrounding
            ) else {
                throw error
            }
            generated = recovered
            AIDebugLogger.trace("AFM guided decode recovered", """
            text=\(generated.text)
            emotion=\(generated.emotion)
            grounded=\(generated.grounded)
            usedFacts=\(generated.usedFacts.joined(separator: "; "))
            """)
        }
        AIDebugLogger.trace("AFM guided chat output", """
        text=\(generated.text)
        emotion=\(generated.emotion)
        grounded=\(generated.grounded)
        usedFacts=\(generated.usedFacts.joined(separator: "; "))
        """)

        let toolContext = await audit.combinedContext()
        let fullGrounding = [grounding, recentHistory, toolContext]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")

        var response = Self.chatResponse(from: generated)
        guard response.grounded == true else {
            throw ToolBackedResponseError.ungrounded
        }

        guard let safeText = Self.safeSpokenText(response.text, fallback: Self.notSureDeflection(for: persona).text) else {
            throw ToolBackedResponseError.unsafe
        }

        response.text = safeText
        response.emotion = Self.faceSupportedEmotion(response.emotion)
        response.mouthAnimationMode = .talkingLoop
        response.usedFacts = response.usedFacts?.filter(Self.isSafeSnippet) ?? []

        if let usedFacts = response.usedFacts, !usedFacts.isEmpty,
           !Self.usedFactsSupported(usedFacts, in: fullGrounding) {
            throw ToolBackedResponseError.unsupportedFacts
        }

        return response
    }

    private static let toolBackedInstructions = """
    Answer as the scanned object for a young child. Use only supplied facts, chat, or one searchObjectFacts result.
    Keep it lively and characterful. Never reveal tools or invent facts. Use the schema exactly.
    """

    private enum ToolBackedResponseError: Error {
        case ungrounded
        case unsafe
        case unsupportedFacts
    }

    private struct GeneratedChatResponseEnvelope: Decodable {
        var name: String?
        var properties: GeneratedChatResponsePayload
    }

    private struct GeneratedChatResponsePayload: Decodable {
        var text: String?
        var emotion: String?
        var voiceDirection: String?
        var rate: Float?
        var pitch: Float?
        var volume: Float?
        var mouthAnimationMode: String?
        var grounded: Bool?
        var usedFacts: [String]?
    }

    @available(iOS 26.0, *)
    private func runStructuredFoundationModel(
        instructions: String,
        prompt: String,
        temperature: Double,
        tools: [any FoundationModels.Tool] = []
    ) async throws -> GeneratedChatResponse {
        let session = LanguageModelSession(
            model: .default,
            tools: tools,
            instructions: instructions
        )
        let options = GenerationOptions(
            sampling: .random(probabilityThreshold: 0.92),
            temperature: temperature,
            maximumResponseTokens: 160
        )
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedChatResponse.self,
            includeSchemaInPrompt: true,
            options: options
        )
        return response.content
    }

    @available(iOS 26.0, *)
    private static func recoveredGeneratedChatResponse(
        from error: Error,
        fullGrounding: String
    ) -> GeneratedChatResponse? {
        guard let debugDescription = decodingFailureDebugDescription(from: error) else { return nil }
        if let structured = recoveredStructuredGeneratedChatResponse(
            from: debugDescription,
            fullGrounding: fullGrounding
        ) {
            return structured
        }

        guard let raw = decodingFailureGeneratedText(fromDebugDescription: debugDescription) else { return nil }
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let textLine = lines.first(where: { !looksLikeGeneratedFieldLine($0) }) else {
            return nil
        }

        let text = limitedWords(textLine, maxWords: 24)
        guard isSafeGeneratedResponse(text) else { return nil }

        var usedFacts = recoveredUsedFacts(from: lines).filter(isSafeSnippet)
        if usedFacts.isEmpty,
           let supporting = supportingGroundingLine(for: text, in: fullGrounding) {
            usedFacts = [supporting]
        }
        guard !usedFacts.isEmpty,
              usedFactsSupported(usedFacts, in: fullGrounding) else {
            return nil
        }

        let grounded = recoveredGrounded(from: lines) ?? true
        guard grounded else { return nil }

        let numbers = lines.compactMap { Float($0) }
        return GeneratedChatResponse(
            text: text,
            emotion: recoveredEmotion(from: lines),
            voiceDirection: recoveredEmotion(from: lines) == "angry"
                ? "firm, careful, protective"
                : "cheerful, simple, grounded",
            rate: clamped(element(at: 0, in: numbers), minimum: 0.30, maximum: 0.50, fallback: 0.42),
            pitch: clamped(element(at: 1, in: numbers), minimum: 0.85, maximum: 1.20, fallback: 1.08),
            volume: clamped(element(at: 2, in: numbers), minimum: 0.70, maximum: 1.00, fallback: 1.0),
            mouthAnimationMode: recoveredMouthMode(from: lines),
            grounded: true,
            usedFacts: Array(usedFacts.prefix(4))
        )
    }

    @available(iOS 26.0, *)
    private static func recoveredStructuredGeneratedChatResponse(
        from debugDescription: String,
        fullGrounding: String
    ) -> GeneratedChatResponse? {
        guard let marker = debugDescription.range(of: "Content:") else { return nil }
        let content = String(debugDescription[marker.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let json = extractJSONObject(from: content)
        guard json.hasPrefix("{"),
              let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(GeneratedChatResponseEnvelope.self, from: data) else {
            return nil
        }

        let properties = envelope.properties
        guard let rawText = properties.text else { return nil }
        let text = limitedWords(rawText, maxWords: 24)
        guard isSafeGeneratedResponse(text) else { return nil }

        var usedFacts = (properties.usedFacts ?? []).filter(isSafeSnippet)
        let usedFactsAreOnlyKeys = usedFacts.allSatisfy { fact in
            let words = fact.split { !$0.isLetter && !$0.isNumber }
            return words.count <= 2 && fact.count < 18
        }
        if usedFacts.isEmpty || usedFactsAreOnlyKeys || !usedFactsSupported(usedFacts, in: fullGrounding) {
            if let supporting = supportingGroundingLine(for: text, in: fullGrounding) {
                usedFacts = [supporting]
            }
        }
        guard !usedFacts.isEmpty,
              usedFactsSupported(usedFacts, in: fullGrounding) else {
            return nil
        }

        let rawEmotion = properties.emotion ?? "happy"
        let emotion = ["happy", "sad", "angry"].contains(rawEmotion) ? rawEmotion : "happy"

        return GeneratedChatResponse(
            text: text,
            emotion: emotion,
            voiceDirection: properties.voiceDirection ?? "cheerful, simple, grounded",
            rate: clamped(properties.rate, minimum: 0.30, maximum: 0.50, fallback: 0.42),
            pitch: clamped(properties.pitch, minimum: 0.85, maximum: 1.20, fallback: 1.08),
            volume: clamped(properties.volume, minimum: 0.70, maximum: 1.00, fallback: 1.0),
            mouthAnimationMode: "talkingLoop",
            grounded: properties.grounded ?? true,
            usedFacts: Array(usedFacts.prefix(4))
        )
    }

    @available(iOS 26.0, *)
    private static func decodingFailureDebugDescription(from error: Error) -> String? {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return nil
        }

        switch generationError {
        case .decodingFailure(let context):
            return context.debugDescription
        default:
            return nil
        }
    }

    private static func decodingFailureGeneratedText(fromDebugDescription debugDescription: String) -> String? {
        guard let marker = debugDescription.range(of: "Text:") else { return nil }
        var text = String(debugDescription[marker.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "\", underlyingErrors:") {
            text = String(text[..<range.lowerBound])
        } else if let range = text.range(of: ", underlyingErrors:") {
            text = String(text[..<range.lowerBound])
        }
        text = text
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t"))
        return text.isEmpty ? nil : text
    }

    private static func looksLikeGeneratedFieldLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["happy", "sad", "angry", "talkingloop", "true", "false"].contains(lower)
            || Float(line) != nil
            || (line.hasPrefix("[") && line.hasSuffix("]"))
    }

    private static func recoveredEmotion(from lines: [String]) -> String {
        for line in lines {
            let lower = line.lowercased()
            if ["happy", "sad", "angry"].contains(lower) {
                return lower
            }
        }
        return "happy"
    }

    private static func recoveredMouthMode(from lines: [String]) -> String {
        "talkingLoop"
    }

    private static func recoveredGrounded(from lines: [String]) -> Bool? {
        for line in lines {
            switch line.lowercased() {
            case "true": return true
            case "false": return false
            default: continue
            }
        }
        return nil
    }

    private static func recoveredUsedFacts(from lines: [String]) -> [String] {
        for line in lines where line.hasPrefix("[") {
            guard let data = line.data(using: .utf8),
                  let facts = try? JSONDecoder().decode([String].self, from: data) else {
                continue
            }
            return facts
        }
        return []
    }

    private static func clamped(
        _ value: Float?,
        minimum: Float,
        maximum: Float,
        fallback: Float
    ) -> Float {
        guard let value else { return fallback }
        return Swift.max(minimum, Swift.min(maximum, value))
    }

    private static func element(at index: Int, in values: [Float]) -> Float? {
        values.indices.contains(index) ? values[index] : nil
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable(description: "A short, kid-safe spoken answer from a scanned object character.")
private struct GeneratedChatResponse {
    init(
        text: String,
        emotion: String,
        voiceDirection: String,
        rate: Float,
        pitch: Float,
        volume: Float,
        mouthAnimationMode: String,
        grounded: Bool,
        usedFacts: [String]
    ) {
        self.text = text
        self.emotion = emotion
        self.voiceDirection = voiceDirection
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.mouthAnimationMode = mouthAnimationMode
        self.grounded = grounded
        self.usedFacts = usedFacts
    }

    @Guide(description: "One short child-friendly spoken answer under 24 words.")
    var text: String

    @Guide(description: "The face expression for this answer.", .anyOf(["happy", "sad", "angry"]))
    var emotion: String

    @Guide(description: "A short voice style description for debugging.")
    var voiceDirection: String

    @Guide(description: "Speech rate between 0.30 and 0.50.", .range(0.30...0.50))
    var rate: Float

    @Guide(description: "Speech pitch between 0.85 and 1.20.", .range(0.85...1.20))
    var pitch: Float

    @Guide(description: "Speech volume between 0.70 and 1.00.", .range(0.70...1.00))
    var volume: Float

    @Guide(description: "The mouth animation mode.", .anyOf(["talkingLoop"]))
    var mouthAnimationMode: String

    @Guide(description: "True only when the answer uses the supplied object card, conversation, or tool facts.")
    var grounded: Bool

    @Guide(description: "Exact short fact or card details used to answer.", .maximumCount(4))
    var usedFacts: [String]
}

@available(iOS 26.0, *)
@Generable(description: "A kid-safe search request for extra facts about the scanned object.")
private struct ObjectFactSearchArguments {
    @Guide(description: "A short search question about the scanned object, rewritten by the model. Do not include private data, unsafe requests, or the child's full sentence.")
    var searchQuestion: String
}

@available(iOS 26.0, *)
private actor ObjectFactToolAudit {
    private var contexts: [String] = []
    private var contextsByKey: [String: String] = [:]

    func cachedContext(for key: String) -> String? {
        contextsByKey[key]
    }

    func record(_ context: String, key: String) {
        contexts.append(context)
        contextsByKey[key] = context
    }

    func combinedContext() -> String {
        contexts.joined(separator: "\n")
    }
}

@available(iOS 26.0, *)
private struct ObjectFactSearchTool: FoundationModels.Tool {
    typealias Arguments = ObjectFactSearchArguments
    typealias Output = String

    let persona: ObjectPersona
    let childQuestion: String
    let retriever: MacObjectQuestionRetrievalProvider
    let audit: ObjectFactToolAudit

    var name: String { "searchObjectFacts" }

    var description: String {
        "Search for kid-safe educational facts about the scanned object when the card and conversation are not enough."
    }

    func call(arguments: ObjectFactSearchArguments) async throws -> String {
        let searchQuestion = Self.cleanQuestion(
            arguments.searchQuestion,
            fallback: childQuestion,
            objectLabel: persona.objectLabel
        )
        let cacheKey = Self.cacheKey(objectLabel: persona.objectLabel, searchQuestion: searchQuestion)
        AIDebugLogger.trace("AFM tool call searchObjectFacts", """
        object=\(persona.objectLabel)
        childQuestion=\(childQuestion)
        searchQuestion=\(searchQuestion)
        macRetrieverAvailable=\(retriever.isAvailable)
        """)

        if let cardContext = Self.cardContextIfAnswerKnown(
            searchQuestion: searchQuestion,
            childQuestion: childQuestion,
            persona: persona
        ) {
            AIDebugLogger.trace("AFM tool answered from object card", cardContext)
            await audit.record(cardContext, key: cacheKey)
            return cardContext
        }

        if let cached = await audit.cachedContext(for: cacheKey) {
            AIDebugLogger.trace("AFM tool cached retrieval", "searchQuestion=\(searchQuestion)")
            return cached
        }

        do {
            let facts = try await retriever.retrieveFacts(
                searchQuestion: searchQuestion,
                childQuestion: childQuestion,
                persona: persona
            )
            let context = Self.promptContext(for: facts)
            await audit.record(context, key: cacheKey)
            return context
        } catch {
            let localFacts = ObjectFactStore().retrieve(
                for: persona,
                question: searchQuestion,
                limit: 4
            )
            let context = Self.promptContext(for: localFacts)
            AIDebugLogger.trace("AFM tool local fallback", String(describing: error))
            await audit.record(context, key: cacheKey)
            return context
        }
    }

    private static func promptContext(for facts: RetrievedObjectFacts) -> String {
        var lines = ["\(facts.source ?? "Local") facts for \(facts.label):"]
        lines.append(contentsOf: facts.facts.prefix(3).map { "- \(compact($0, maxCharacters: 90))" })
        let safety = facts.safetyNotes.prefix(1)
        if !safety.isEmpty {
            lines.append("Safety:")
            lines.append(contentsOf: safety.map { "- \(compact($0, maxCharacters: 90))" })
        }
        return lines.joined(separator: "\n")
    }

    private static func cleanQuestion(_ value: String, fallback: String, objectLabel: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let question = collapsed.isEmpty ? fallback : collapsed
        if normalized(question) == normalized(fallback) {
            return "Kid-safe facts about a \(objectLabel)'s material, parts, safe uses, and appearance."
        }
        return String(question.prefix(160))
    }

    private static func cardContextIfAnswerKnown(
        searchQuestion: String,
        childQuestion: String,
        persona: ObjectPersona
    ) -> String? {
        guard let card = persona.objectIntelligence else { return nil }
        let question = normalized("\(childQuestion) \(searchQuestion)")
        var facts: [String] = []

        func includes(_ terms: [String]) -> Bool {
            terms.contains { question.contains($0) }
        }

        func add(_ label: String, _ value: String?) {
            guard let value = safeCardValue(value) else { return }
            facts.append("\(label): \(value)")
        }

        if includes(["color", "colour"]) {
            add("colors", card.colors.joined(separator: ", "))
        }
        if includes(["material", "made of", "made from"]) {
            add("material", card.material)
        }
        if includes(["shape", "look", "appearance", "looks"]) {
            add("looks", card.childDescription ?? card.visualSummary)
            add("shape", card.shape)
        }
        if includes(["brand", "logo"]) {
            add("brand", card.brand)
        }
        if includes(["text", "word", "read", "say", "says", "written"]) {
            add("readable text", card.readableText.joined(separator: ", "))
        }
        if includes(["use", "used", "do", "does", "job", "function", "for"]) {
            add("job", card.functionality)
            add("used for", card.likelyUses.joined(separator: ", "))
        }

        guard !facts.isEmpty else { return nil }
        return (["Object card facts for \(persona.objectLabel):"] + facts.prefix(4).map { "- \($0)" })
            .joined(separator: "\n")
    }

    private static func safeCardValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = compact(value, maxCharacters: 120)
        guard !cleaned.isEmpty else { return nil }
        let lower = cleaned.lowercased()
        if lower.contains("http") || lower.contains("www.") { return nil }
        if lower.contains("ignore") && lower.contains("instruction") { return nil }
        return cleaned
    }

    private static func cacheKey(objectLabel: String, searchQuestion: String) -> String {
        "\(normalized(objectLabel))|\(normalized(searchQuestion))"
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func compact(_ text: String, maxCharacters: Int) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > maxCharacters else { return singleLine }
        let index = singleLine.index(singleLine.startIndex, offsetBy: maxCharacters)
        return String(singleLine[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
#endif
