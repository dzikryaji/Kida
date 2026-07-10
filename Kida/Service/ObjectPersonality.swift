import Foundation

/// Kida's five starter personalities. A scanned object is assigned the closest one:
/// the **AR layer** renders `accessory` as a 3D prop on the face, the **AI layer** makes
/// the Foundation Model speak in `voice`. A starting taxonomy, not rigid rules.
///
/// Source of truth = the scanned object. VLM/Gemini may suggest a flavor, but strong
/// object taxonomy and safety overrides keep the AR accessory stable and varied.
enum PersonalityKind: String, Codable, CaseIterable, Sendable {
    case boss        // round glasses — authority / money / "holds power"
    case cool        // sunglasses — sport / play / trendy
    case fancy       // bow tie — formal / elegant / special-occasion
    case caregiver   // hair bow — soft / comfort / care
    case cautious    // small helmet — dangerous objects: careful, never scary

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch rawValue {
        case "boss": self = .boss
        case "cool": self = .cool
        case "fancy": self = .fancy
        case "caregiver", "sweet": self = .caregiver
        case "cautious": self = .cautious
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown personality kind: \(rawValue)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch self {
        case .boss: return "The Boss"
        case .cool: return "The Cool"
        case .fancy: return "The Fancy"
        case .caregiver: return "The Caregiver"
        case .cautious: return "The Cautious"
        }
    }

    /// Identifier for the 3D accessory the AR layer places on the face.
    /// (AR side must have a model registered under each of these names.)
    var accessory: String {
        switch self {
        case .boss: return "round_glasses"
        case .cool: return "sunglasses"
        case .fancy: return "bow_tie"
        case .caregiver: return "hair_bow"
        case .cautious: return "helmet"
        }
    }

    /// In-character voice the Foundation Model adopts. Warm + kid-safe for every kind.
    var voice: String {
        switch self {
        case .boss: return "confident and in charge, like a friendly little leader — warm, never bossy or mean"
        case .cool: return "playful, sporty and upbeat, like a fun best friend"
        case .fancy: return "polished and gentle, delighted by pretty and special things"
        case .caregiver: return "soft, warm and caring, like a cozy friend who gives comfort"
        case .cautious: return "calm and careful — gently reminds the child to stay safe and ask a grown-up; reassuring, never scary"
        }
    }

    /// Resting face emotion for the character.
    var defaultEmotion: Emotion {
        switch self {
        case .boss: return .happy
        case .cool: return .happy
        case .fancy: return .happy
        case .caregiver: return .happy
        case .cautious: return .happy
        }
    }

    /// Stable voice family chosen at scan time. Swift maps gender + emotion to concrete IDs;
    /// family keeps the character direction consistent without exposing provider voice IDs.
    var defaultVoiceFamily: VoiceFamily {
        switch self {
        case .boss: return .confident
        case .cool: return .bright
        case .fancy: return .gentle
        case .caregiver: return .gentle
        case .cautious: return .careful
        }
    }
}

/// Assigns a personality from the object while keeping object risk separate.
enum PersonalityMapper {
    /// Final personality for an object. Only validated high risk hard-overrides the
    /// VLM/Gemini choice; contextual objects keep their normal character.
    static func resolve(
        suggested: PersonalityKind?,
        label: String,
        riskLevel: ObjectRiskLevel
    ) -> PersonalityKind {
        if riskLevel == .high { return .cautious }
        if let mapped = explicitMapFromLabel(label) { return mapped }
        return suggested ?? .cool
    }

    /// Keyword fallback when the VLM didn't classify (deterministic, per the design doc).
    static func mapFromLabel(_ label: String) -> PersonalityKind {
        if resolvedRiskLevel(suggested: nil, label: label) == .high { return .cautious }
        if let mapped = explicitMapFromLabel(label) { return mapped }
        return .cool   // friendly, low-stakes default
    }

    /// Strong taxonomy hits override the VLM when it lazily returns `.cool`.
    /// Unknown/ambiguous labels still let the VLM suggestion win.
    static func explicitMapFromLabel(_ label: String) -> PersonalityKind? {
        let text = label.lowercased()
        if contains(text, bossWords) { return .boss }
        if contains(text, coolWords) { return .cool }
        if contains(text, caregiverWords) { return .caregiver }
        if contains(text, fancyWords) { return .fancy }
        return nil
    }

    /// Resolve the VLM's structured risk suggestion against a conservative local policy.
    /// Generic safety notes are intentionally excluded: advice is not hazard evidence.
    static func resolvedRiskLevel(
        suggested: ObjectRiskLevel?,
        label: String,
        evidence: [String] = []
    ) -> ObjectRiskLevel {
        let labelText = label.lowercased()
        let evidenceText = evidence.joined(separator: " ").lowercased()
        let hasActiveHazard = contains(evidenceText, activeHighRiskEvidence)

        if contains(labelText, highRiskWords) {
            let canDowngrade = contains(labelText, downgradableHighRiskWords)
                && contains(labelText, lowRiskQualifiers)
                && !hasActiveHazard
            return canDowngrade ? .contextual : .high
        }

        if suggested == .high, hasActiveHazard {
            return .high
        }

        if contains(labelText, contextualRiskWords) || suggested == .contextual || suggested == .high {
            return .contextual
        }
        return .none
    }

    static func isHighRisk(
        label: String,
        suggested: ObjectRiskLevel? = nil,
        evidence: [String] = []
    ) -> Bool {
        resolvedRiskLevel(suggested: suggested, label: label, evidence: evidence) == .high
    }

    private static func contains(_ text: String, _ terms: [String]) -> Bool {
        let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return terms.contains { rawTerm in
            let term = rawTerm.lowercased()
            if term.contains(" ") {
                return text.contains(term)
            }
            return wordVariants(for: term).contains { words.contains($0) }
        }
    }

    private static func wordVariants(for term: String) -> [String] {
        var variants = [term, "\(term)s"]
        if term.hasSuffix("s") || term.hasSuffix("x") || term.hasSuffix("ch") {
            variants.append("\(term)es")
        }
        if term == "knife" {
            variants.append("knives")
        }
        return variants
    }

    static let highRiskWords = [
        "knife", "scissor", "blade", "razor", "stove", "oven", "outlet", "socket",
        "lighter", "medicine", "pill", "syringe", "needle", "chemical cleaner", "bleach",
        "poison", "toxic chemical", "firearm", "gun", "weapon", "saw", "power drill",
        "broken glass", "glass shard", "shard",
    ]
    static let contextualRiskWords = [
        "fork", "tine", "prong", "kettle", "pan", "pot", "toaster", "microwave",
        "iron", "heater", "candle", "match", "drill", "hammer", "screwdriver", "nail",
        "tool", "plug", "cord", "battery", "wire", "cable", "electric", "electrical",
        "detergent", "cleaner", "spray", "aerosol",
    ]
    static let activeHighRiskEvidence = [
        "visible flame", "open flame", "lit candle", "is burning", "currently burning",
        "boiling", "steaming", "glowing hot", "exposed wire", "exposed wiring",
        "sparking", "leaking chemical", "spilled chemical", "broken into shards",
    ]
    static let downgradableHighRiskWords = [
        "knife", "scissor", "gun", "weapon", "saw", "power drill",
    ]
    static let lowRiskQualifiers = [
        "toy", "pretend", "costume prop", "display prop", "child safe", "child-safe",
        "safety scissor", "butter knife", "training knife",
    ]
    static let coolWords = [
        "ball", "skateboard", "sneaker", "shoe", "headphone", "earbud", "sunglass",
        "bicycle", "bike", "scooter", "controller", "sport", "guitar", "cap",
        "game", "toy car", "frisbee",
    ]
    static let caregiverWords = [
        "pillow", "blanket", "plush", "stuffed", "teddy", "doll", "toy", "teapot",
        "tissue", "tissue box", "cushion", "mug", "flower", "bear", "bunny", "baby",
        "baby bottle", "soft",
    ]
    static let fancyWords = [
        "perfume", "wine", "champagne", "vase", "frame", "jewel", "ring", "necklace",
        "crystal", "trophy", "medal", "bow tie", "watch", "photo", "glassware",
        "tableware", "decorative", "fork", "spoon", "plate", "cutlery", "utensil",
    ]
    static let bossWords = [
        "money", "cash", "wallet", "credit card", "coin", "safe", "piggy", "remote",
        "key", "calculator", "book", "clock", "phone", "laptop", "computer", "tablet",
        "badge", "card",
    ]

    #if DEBUG
    /// ponytail: one runnable check for the mapper. Call from a test or SwiftUI preview.
    static func _selfCheck() {
        assert(resolve(suggested: .caregiver, label: "medicine bottle", riskLevel: .high) == .cautious, "high risk must override")
        assert(resolve(suggested: nil, label: "kitchen knife", riskLevel: .high) == .cautious)
        assert(resolvedRiskLevel(suggested: nil, label: "fork") == .contextual)
        assert(resolve(suggested: .fancy, label: "fork", riskLevel: .contextual) == .fancy)
        assert(resolvedRiskLevel(suggested: nil, label: "charging cable") == .contextual)
        assert(resolve(suggested: .fancy, label: "cable organizer", riskLevel: .contextual) == .fancy)
        assert(resolvedRiskLevel(suggested: .high, label: "candle", evidence: ["A visible flame is burning."]) == .high)
        assert(resolvedRiskLevel(suggested: .high, label: "candle", evidence: ["Candles can burn things."]) == .contextual)
        assert(resolvedRiskLevel(suggested: .high, label: "toy gun") == .contextual)
        assert(resolvedRiskLevel(suggested: nil, label: "safety scissors") == .contextual)
        assert(resolve(suggested: nil, label: "skateboard", riskLevel: .none) == .cool)
        assert(resolve(suggested: nil, label: "teddy bear", riskLevel: .none) == .caregiver)
        assert(resolve(suggested: nil, label: "wine glass", riskLevel: .none) == .fancy)
        assert(resolve(suggested: nil, label: "wallet", riskLevel: .none) == .boss)
        assert(resolve(suggested: .cool, label: "laptop", riskLevel: .none) == .boss, "strong taxonomy beats lazy VLM")
        assert(resolve(suggested: .boss, label: "banana", riskLevel: .none) == .boss, "VLM pick honored when safe")
    }
    #endif
}

extension ObjectIntelligenceCard {
    var resolvedRiskLevel: ObjectRiskLevel {
        PersonalityMapper.resolvedRiskLevel(
            suggested: riskLevel,
            label: primaryLabel,
            evidence: [riskReason, visualSummary, childDescription, shape]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        )
    }
}

// MARK: - Bridge to the AR layer (friend's FaceEntityFactory)

extension PersonalityKind {
    /// Maps to the AR face personality. 1:1 with the five AR personalities.
    var faceKind: FaceEntityFactory.Personality {
        switch self {
        case .boss: return .boss
        case .cool: return .cool
        case .fancy: return .fancy
        case .caregiver: return .caregiver
        case .cautious: return .cautious
        }
    }
}

extension Emotion {
    /// Collapses the 9 emotions to the AR face's 3 expressions.
    var faceExpression: FaceEntityFactory.Expression {
        switch self {
        case .angry: return .angry
        case .sad: return .sad
        default: return .happy
        }
    }

    /// ElevenLabs voice bucket (happy / angry / sad).
    var voiceKey: String {
        switch self {
        case .angry: return "angry"
        case .sad: return "sad"
        default: return "happy"
        }
    }
}

extension VoiceGender {
    /// Launch-stable fallback so an object keeps the same gender when VLM does not choose one.
    static func stableDefault(for label: String) -> VoiceGender {
        let seed = label.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return seed % 2 == 0 ? .woman : .man
    }
}
