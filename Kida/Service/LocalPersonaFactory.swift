import Foundation

struct LocalPersonaFactory {
    func makePersona(for detectedObject: DetectedObject) -> ObjectPersona {
        let label = ObjectLabelNormalizer.normalize(detectedObject.label)

        switch label {
        case "cup":
            return ObjectPersona(
                name: "Curio Cup",
                objectLabel: label,
                personality: "cheerful helper who loves healthy sips",
                voiceProfile: .cheerful,
                emotionStyle: .happy,
                greeting: "Hi! I am Curio Cup. I help you drink water when you are thirsty.",
                kidFriendlyFacts: [
                    "Cups can hold drinks so our hands stay dry.",
                    "Some cups keep drinks warm, and some keep them cool."
                ],
                visualContext: detectedObject.visualContext
            )
        case "plant":
            return ObjectPersona(
                name: "Pip the Plant",
                objectLabel: label,
                personality: "gentle nature friend who notices sunlight",
                voiceProfile: .thoughtful,
                emotionStyle: .happy,
                greeting: "Hello, I am Pip the Plant. I grow slowly with light, water, and care.",
                kidFriendlyFacts: [
                    "Many plants use sunlight to make their own food.",
                    "Roots help plants drink water from the soil."
                ],
                visualContext: detectedObject.visualContext
            )
        case "book":
            return ObjectPersona(
                name: "Bibi Book",
                objectLabel: label,
                personality: "wise storyteller who loves questions",
                voiceProfile: .thoughtful,
                emotionStyle: .happy,
                greeting: "Hi, I am Bibi Book. I carry stories, ideas, and little surprises on my pages.",
                kidFriendlyFacts: [
                    "Books can teach facts or tell imaginary stories.",
                    "Turning pages helps you travel through the story step by step."
                ],
                visualContext: detectedObject.visualContext
            )
        case "chair":
            return ObjectPersona(
                name: "Captain Chair",
                objectLabel: label,
                personality: "steady helper who supports tired legs",
                voiceProfile: .cheerful,
                emotionStyle: .happy,
                greeting: "Hello! I am Captain Chair. I help people rest, read, draw, and think.",
                kidFriendlyFacts: [
                    "A chair spreads your weight through its seat and legs.",
                    "Some chairs roll, fold, spin, or rock."
                ],
                visualContext: detectedObject.visualContext
            )
        case "bottle":
            return ObjectPersona(
                name: "Bop Bottle",
                objectLabel: label,
                personality: "energetic explorer who carries drinks safely",
                voiceProfile: .excited,
                emotionStyle: .happy,
                greeting: "Hi! I am Bop Bottle. I carry water so you can sip it wherever you go.",
                kidFriendlyFacts: [
                    "A lid helps keep liquid from spilling.",
                    "Reusable bottles can help reduce trash."
                ],
                visualContext: detectedObject.visualContext
            )
        default:
            let displayName = label.capitalized
            return ObjectPersona(
                name: "Kida \(displayName)",
                objectLabel: label,
                personality: "friendly explorer who likes explaining everyday things",
                voiceProfile: .cheerful,
                emotionStyle: .happy,
                greeting: "Hi! I am \(displayName). I am ready to explore what I do with you.",
                kidFriendlyFacts: [
                    "Every object has a shape, a material, and a job.",
                    "Looking closely is a great way to learn."
                ],
                visualContext: detectedObject.visualContext
            )
        }
    }

    func makeResponse(for message: String, persona: ObjectPersona) -> ChatResponse {
        let lowercased = message.lowercased()
        let label = persona.objectLabel

        if lowercased.contains("what are you") || lowercased.contains("who are you") {
            return ChatResponse(
                text: "I am \(persona.name), a \(label). I love helping kids learn.",
                emotion: .happy,
                voiceDirection: "cheerful, gentle, playful",
                rate: 0.46,
                pitch: 1.2,
                volume: 1.0,
                mouthAnimationMode: .talkingLoop
            )
        }

        if lowercased.contains("help") || lowercased.contains("do") {
            return ChatResponse(
                text: "My job is simple: I help people every day as a \(label).",
                emotion: .happy,
                voiceDirection: "curious, warm, explanatory",
                rate: 0.44,
                pitch: 1.12,
                volume: 1.0,
                mouthAnimationMode: .talkingLoop
            )
        }

        if lowercased.contains("fun") || lowercased.contains("fact") || lowercased.contains("learn") {
            let fact = persona.kidFriendlyFacts.first ?? "If you look carefully, every object can teach you something."
            return ChatResponse(
                text: fact,
                emotion: .happy,
                voiceDirection: "bright, excited, kid-friendly",
                rate: 0.5,
                pitch: 1.25,
                volume: 1.0,
                mouthAnimationMode: .talkingLoop
            )
        }

        if lowercased.contains("sad") || lowercased.contains("angry") || lowercased.contains("scared") {
            return ChatResponse(
                text: "Big feelings are okay. Let us breathe slowly, then keep learning.",
                emotion: .sad,
                voiceDirection: "slow, gentle, reassuring",
                rate: 0.39,
                pitch: 1.02,
                volume: 0.9,
                mouthAnimationMode: .talkingLoop
            )
        }

        return ChatResponse(
            text: "Great question. Look at my shape and material for clues.",
            emotion: .happy,
            voiceDirection: "curious, friendly, thoughtful",
            rate: 0.43,
            pitch: 1.12,
            volume: 1.0,
            mouthAnimationMode: .talkingLoop
        )
    }
}
