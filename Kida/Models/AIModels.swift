import Foundation
import UIKit

struct ObjectIntelligenceCard: Codable, Equatable, Sendable {
    var primaryLabel: String
    var confidence: Float
    var visualSummary: String
    var colors: [String]
    var material: String?
    var shape: String?
    var readableText: [String]
    var likelyUses: [String]
    var safetyNotes: [String]
    var uncertainty: String?
    /// VLM-suggested personality bucket. Code may override to `.cautious` for danger.
    var personality: PersonalityKind?
    /// VLM-suggested resting emotion for the character's face.
    var emotion: Emotion?

    init(
        primaryLabel: String,
        confidence: Float,
        visualSummary: String,
        colors: [String] = [],
        material: String? = nil,
        shape: String? = nil,
        readableText: [String] = [],
        likelyUses: [String] = [],
        safetyNotes: [String] = [],
        uncertainty: String? = nil,
        personality: PersonalityKind? = nil,
        emotion: Emotion? = nil
    ) {
        self.primaryLabel = ObjectLabelNormalizer.normalize(primaryLabel)
        self.confidence = confidence
        self.visualSummary = visualSummary
        self.colors = colors
        self.material = material
        self.shape = shape
        self.readableText = readableText
        self.likelyUses = likelyUses
        self.safetyNotes = safetyNotes
        self.uncertainty = uncertainty
        self.personality = personality
        self.emotion = emotion
    }

    enum CodingKeys: String, CodingKey {
        case primaryLabel
        case confidence
        case visualSummary
        case colors
        case material
        case shape
        case readableText
        case likelyUses
        case safetyNotes
        case uncertainty
        case personality
        case emotion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawLabel = try container.decodeIfPresent(String.self, forKey: .primaryLabel)
        let rawSummary = try container.decodeIfPresent(String.self, forKey: .visualSummary)
        primaryLabel = ObjectLabelNormalizer.normalize(rawLabel ?? "object")
        confidence = try container.decodeFlexibleFloat(forKey: .confidence) ?? 0
        visualSummary = rawSummary ?? "No visual summary available."
        colors = try container.decodeIfPresent([String].self, forKey: .colors) ?? []
        material = try container.decodeIfPresent(String.self, forKey: .material)
        shape = try container.decodeIfPresent(String.self, forKey: .shape)
        readableText = try container.decodeIfPresent([String].self, forKey: .readableText) ?? []
        likelyUses = try container.decodeIfPresent([String].self, forKey: .likelyUses) ?? []
        safetyNotes = try container.decodeIfPresent([String].self, forKey: .safetyNotes) ?? []
        let rawUncertainty = try container.decodeIfPresent(String.self, forKey: .uncertainty)
        // Corrupt/degenerate-card guard: if the identifying fields were missing the
        // payload was likely truncated or empty — never let it read as confident.
        if rawLabel == nil || rawSummary == nil {
            uncertainty = "high"
            confidence = min(confidence, 0.2)
        } else {
            uncertainty = rawUncertainty
        }
        // Lenient: an unknown personality/emotion string degrades to nil, never fails the card.
        personality = (try? container.decodeIfPresent(PersonalityKind.self, forKey: .personality)) ?? nil
        emotion = (try? container.decodeIfPresent(Emotion.self, forKey: .emotion)) ?? nil
    }
}

private extension KeyedDecodingContainer where Key == ObjectIntelligenceCard.CodingKeys {
    func decodeFlexibleFloat(forKey key: Key) throws -> Float? {
        if let value = try? decodeIfPresent(Float.self, forKey: key) {
            return value
        }

        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Float(value)
        }

        if let text = try? decodeIfPresent(String.self, forKey: key),
           let value = Float(text) {
            return value
        }

        return nil
    }
}

enum Emotion: String, Codable, CaseIterable {
    case neutral
    case happy
    case angry
    case sad
    case curious
    case surprised
    case thinking
    case confused
    case excited

    var displayName: String {
        rawValue.capitalized
    }
}

enum MouthShape: String, Codable {
    case closed
    case smallOpen
    case open
    case wideOpen
    case smile
    case oShape
}

enum MouthAnimationMode: String, Codable {
    case idle
    case talkingLoop
    case thinking
    case surprised
}

struct VoiceProfile: Codable, Equatable {
    var voiceIdentifier: String?
    var rate: Float
    var pitch: Float
    var volume: Float

    static let cheerful = VoiceProfile(voiceIdentifier: nil, rate: 0.42, pitch: 1.08, volume: 1.0)
    static let thoughtful = VoiceProfile(voiceIdentifier: nil, rate: 0.38, pitch: 1.0, volume: 1.0)
    static let excited = VoiceProfile(voiceIdentifier: nil, rate: 0.45, pitch: 1.12, volume: 1.0)
}

struct ObjectPersona: Identifiable, Codable {
    let id: UUID
    var name: String
    var objectLabel: String
    var personality: String
    var personalityKind: PersonalityKind
    var voiceProfile: VoiceProfile
    var emotionStyle: Emotion
    var greeting: String
    var kidFriendlyFacts: [String]
    var visualContext: String?
    var objectIntelligence: ObjectIntelligenceCard?
    var retrievedFacts: RetrievedObjectFacts?

    init(
        id: UUID = UUID(),
        name: String,
        objectLabel: String,
        personality: String,
        personalityKind: PersonalityKind = .cool,
        voiceProfile: VoiceProfile,
        emotionStyle: Emotion,
        greeting: String,
        kidFriendlyFacts: [String],
        visualContext: String? = nil,
        objectIntelligence: ObjectIntelligenceCard? = nil,
        retrievedFacts: RetrievedObjectFacts? = nil
    ) {
        self.id = id
        self.name = name
        self.objectLabel = objectLabel
        self.personality = personality
        self.personalityKind = personalityKind
        self.voiceProfile = voiceProfile
        self.emotionStyle = emotionStyle
        self.greeting = greeting
        self.kidFriendlyFacts = kidFriendlyFacts
        self.visualContext = visualContext
        self.objectIntelligence = objectIntelligence
        self.retrievedFacts = retrievedFacts
    }

    enum CodingKeys: String, CodingKey {
        case name
        case objectLabel
        case personality
        case personalityKind
        case voiceProfile
        case emotionStyle
        case greeting
        case kidFriendlyFacts
        case visualContext
        case objectIntelligence
        case retrievedFacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        name = try container.decode(String.self, forKey: .name)
        objectLabel = try container.decode(String.self, forKey: .objectLabel)
        personality = try container.decode(String.self, forKey: .personality)
        personalityKind = try container.decodeIfPresent(PersonalityKind.self, forKey: .personalityKind) ?? .cool
        voiceProfile = try container.decode(VoiceProfile.self, forKey: .voiceProfile)
        emotionStyle = try container.decode(Emotion.self, forKey: .emotionStyle)
        greeting = try container.decode(String.self, forKey: .greeting)
        kidFriendlyFacts = try container.decode([String].self, forKey: .kidFriendlyFacts)
        visualContext = try container.decodeIfPresent(String.self, forKey: .visualContext)
        objectIntelligence = try container.decodeIfPresent(ObjectIntelligenceCard.self, forKey: .objectIntelligence)
        retrievedFacts = try container.decodeIfPresent(RetrievedObjectFacts.self, forKey: .retrievedFacts)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(objectLabel, forKey: .objectLabel)
        try container.encode(personality, forKey: .personality)
        try container.encode(personalityKind, forKey: .personalityKind)
        try container.encode(voiceProfile, forKey: .voiceProfile)
        try container.encode(emotionStyle, forKey: .emotionStyle)
        try container.encode(greeting, forKey: .greeting)
        try container.encode(kidFriendlyFacts, forKey: .kidFriendlyFacts)
        try container.encodeIfPresent(visualContext, forKey: .visualContext)
        try container.encodeIfPresent(objectIntelligence, forKey: .objectIntelligence)
        try container.encodeIfPresent(retrievedFacts, forKey: .retrievedFacts)
    }
}

struct ChatResponse: Codable {
    var text: String
    var emotion: Emotion
    var voiceDirection: String
    var rate: Float
    var pitch: Float
    var volume: Float
    var mouthAnimationMode: MouthAnimationMode
    /// Whether the model reported it answered strictly from the supplied facts/card.
    var grounded: Bool?
    /// Fact/card snippets the model said it used (grounding audit trail).
    var usedFacts: [String]?

    var voiceProfile: VoiceProfile {
        VoiceProfile(
            voiceIdentifier: nil,
            rate: rate,
            pitch: pitch,
            volume: volume
        )
    }

    init(
        text: String,
        emotion: Emotion,
        voiceDirection: String = "cheerful, gentle, playful",
        rate: Float = 0.42,
        pitch: Float = 1.08,
        volume: Float = 1.0,
        mouthAnimationMode: MouthAnimationMode,
        grounded: Bool? = nil,
        usedFacts: [String]? = nil
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

    enum CodingKeys: String, CodingKey {
        case text
        case emotion
        case voiceDirection
        case rate
        case pitch
        case volume
        case mouthAnimationMode
        case grounded
        case usedFacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        emotion = try container.decode(Emotion.self, forKey: .emotion)
        voiceDirection = try container.decodeIfPresent(String.self, forKey: .voiceDirection) ?? "cheerful, gentle, playful"
        rate = try container.decodeIfPresent(Float.self, forKey: .rate) ?? 0.42
        pitch = try container.decodeIfPresent(Float.self, forKey: .pitch) ?? 1.08
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        mouthAnimationMode = try container.decodeIfPresent(MouthAnimationMode.self, forKey: .mouthAnimationMode) ?? .talkingLoop
        grounded = try container.decodeIfPresent(Bool.self, forKey: .grounded)
        usedFacts = try container.decodeIfPresent([String].self, forKey: .usedFacts)
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case child
        case object
    }

    let id = UUID()
    var role: Role
    var text: String
    var emotion: Emotion?
    var createdAt = Date()
}
