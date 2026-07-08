import Foundation

/// Kida's five starter personalities. A scanned object is assigned the closest one:
/// the **AR layer** renders `accessory` as a 3D prop on the face, the **AI layer** makes
/// the Foundation Model speak in `voice`. A starting taxonomy, not rigid rules.
///
/// Source of truth = the VLM/Gemini structured output (it sees the image). Code only
/// *overrides* to `.cautious` for dangerous objects — safety beats flavor (see PersonalityMapper).
enum PersonalityKind: String, Codable, CaseIterable, Sendable {
    case boss        // round glasses — authority / money / "holds power"
    case cool        // sunglasses — sport / play / trendy
    case fancy       // bow tie — formal / elegant / special-occasion
    case sweet       // hair bow — soft / comfort / care
    case cautious    // small helmet — dangerous objects: careful, never scary

    var title: String {
        switch self {
        case .boss: return "The Boss"
        case .cool: return "The Cool"
        case .fancy: return "The Fancy"
        case .sweet: return "The Sweet"
        case .cautious: return "The Careful"
        }
    }

    /// Identifier for the 3D accessory the AR layer places on the face.
    /// (AR side must have a model registered under each of these names.)
    var accessory: String {
        switch self {
        case .boss: return "round_glasses"
        case .cool: return "sunglasses"
        case .fancy: return "bow_tie"
        case .sweet: return "hair_bow"
        case .cautious: return "helmet"
        }
    }

    /// In-character voice the Foundation Model adopts. Warm + kid-safe for every kind.
    var voice: String {
        switch self {
        case .boss: return "confident and in charge, like a friendly little leader — warm, never bossy or mean"
        case .cool: return "playful, sporty and upbeat, like a fun best friend"
        case .fancy: return "polished and gentle, delighted by pretty and special things"
        case .sweet: return "soft, warm and caring, like a cozy friend who gives comfort"
        case .cautious: return "calm and careful — gently reminds the child to stay safe and ask a grown-up; reassuring, never scary"
        }
    }

    /// Resting face emotion for the character.
    var defaultEmotion: Emotion {
        switch self {
        case .boss: return .neutral
        case .cool: return .excited
        case .fancy: return .happy
        case .sweet: return .happy
        case .cautious: return .thinking
        }
    }
}

/// Assigns a personality from the object, and enforces the safety override.
enum PersonalityMapper {
    /// Final personality for an object. `suggested` is the VLM/Gemini pick (nil if none).
    /// SAFETY FIRST: a dangerous object is always `.cautious`, whatever the VLM said.
    static func resolve(
        suggested: PersonalityKind?,
        label: String,
        safetyNotes: [String] = []
    ) -> PersonalityKind {
        if isDangerous(label: label, safetyNotes: safetyNotes) { return .cautious }
        return suggested ?? mapFromLabel(label)
    }

    /// Keyword fallback when the VLM didn't classify (deterministic, per the design doc).
    static func mapFromLabel(_ label: String) -> PersonalityKind {
        let text = label.lowercased()
        if contains(text, coolWords) { return .cool }
        if contains(text, sweetWords) { return .sweet }
        if contains(text, fancyWords) { return .fancy }
        if contains(text, bossWords) { return .boss }
        return .cool   // friendly, low-stakes default
    }

    /// Danger drives both `.cautious` and the kid-safety guardrail. Over-triggering is the
    /// SAFE failure mode (an over-careful teddy is harmless; a careless knife is not), so the
    /// list is deliberately broad and the VLM's own safetyNotes are also consulted.
    static func isDangerous(label: String, safetyNotes: [String] = []) -> Bool {
        let text = (label + " " + safetyNotes.joined(separator: " ")).lowercased()
        return contains(text, dangerWords)
    }

    private static func contains(_ text: String, _ words: [String]) -> Bool {
        words.contains { text.contains($0) }
    }

    static let dangerWords = [
        "knife", "scissor", "blade", "razor", "stove", "oven", "heater", "outlet",
        "socket", "plug", "cord", "battery", "lighter", "match", "candle", "flame",
        "medicine", "pill", "syringe", "needle", "chemical", "cleaner", "bleach", "sharp",
    ]
    static let coolWords = [
        "ball", "skateboard", "sneaker", "shoe", "headphone", "earbud", "sunglass",
        "bicycle", "bike", "scooter", "controller", "sport", "guitar", "cap",
    ]
    static let sweetWords = [
        "pillow", "blanket", "plush", "stuffed", "teddy", "doll", "toy", "teapot",
        "tissue", "cushion", "mug", "flower", "bear", "bunny", "baby",
    ]
    static let fancyWords = [
        "perfume", "wine", "champagne", "vase", "frame", "jewel", "ring", "necklace",
        "crystal", "trophy", "medal", "bow tie", "watch",
    ]
    static let bossWords = [
        "money", "cash", "wallet", "credit card", "coin", "safe", "piggy", "remote",
        "key", "calculator", "book", "clock", "phone", "laptop", "computer", "tablet",
    ]

    #if DEBUG
    /// ponytail: one runnable check for the mapper. Call from a test or SwiftUI preview.
    static func _selfCheck() {
        assert(resolve(suggested: .sweet, label: "medicine bottle") == .cautious, "danger must override")
        assert(resolve(suggested: nil, label: "kitchen knife") == .cautious)
        assert(resolve(suggested: nil, label: "skateboard") == .cool)
        assert(resolve(suggested: nil, label: "teddy bear") == .sweet)
        assert(resolve(suggested: nil, label: "wine glass") == .fancy)
        assert(resolve(suggested: nil, label: "wallet") == .boss)
        assert(resolve(suggested: .boss, label: "banana") == .boss, "VLM pick honored when safe")
    }
    #endif
}
