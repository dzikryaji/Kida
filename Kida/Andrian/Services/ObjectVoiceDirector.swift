import Foundation

enum ObjectVoiceDirector {
    static func applyVoice(to persona: ObjectPersona, for objectLabel: String) -> ObjectPersona {
        var updatedPersona = persona
        updatedPersona.voiceProfile = voiceProfile(
            for: objectLabel,
            base: persona.voiceProfile,
            emotion: persona.emotionStyle
        )
        return updatedPersona
    }

    static func voiceProfile(for objectLabel: String, base: VoiceProfile, emotion: Emotion) -> VoiceProfile {
        let role = role(for: ObjectLabelNormalizer.normalize(objectLabel), emotion: emotion)
        var profile = base

        if let configuredVoiceID = configuredElevenLabsVoiceID(for: role) {
            profile.voiceIdentifier = configuredVoiceID
        } else {
            profile.voiceIdentifier = base.voiceIdentifier
        }

        switch role {
        case .gentle:
            profile.rate = min(profile.rate, 0.39)
            profile.pitch = min(max(profile.pitch, 0.98), 1.08)
        case .wise:
            profile.rate = min(profile.rate, 0.40)
            profile.pitch = min(max(profile.pitch, 0.96), 1.06)
        case .energetic:
            profile.rate = max(profile.rate, 0.45)
            profile.pitch = max(profile.pitch, 1.12)
        case .calm:
            profile.rate = min(profile.rate, 0.38)
            profile.pitch = min(max(profile.pitch, 0.96), 1.04)
            profile.volume = min(profile.volume, 0.92)
        case .cheerful:
            profile.rate = min(max(profile.rate, 0.42), 0.46)
            profile.pitch = min(max(profile.pitch, 1.08), 1.16)
        }

        return profile
    }

    private static func role(for label: String, emotion: Emotion) -> VoiceRole {
        if ["knife", "scissors", "fire", "stove", "oven", "weapon"].contains(label) {
            return .calm
        }

        switch label {
        case "plant":
            return .gentle
        case "book", "laptop", "phone":
            return .wise
        case "bottle", "toy", "ball":
            return .energetic
        case "bag", "chair", "table", "cup":
            return .cheerful
        default:
            return emotion == .excited ? .energetic : .cheerful
        }
    }

    private static func configuredElevenLabsVoiceID(for role: VoiceRole) -> String? {
        let info = Bundle.main.infoDictionary ?? [:]
        let keys = role.infoPlistKeys + ["ElevenLabsVoiceID"]

        for key in keys {
            guard let value = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !value.contains("$(") else {
                continue
            }

            return value
        }

        return nil
    }
}

private enum VoiceRole {
    case cheerful
    case gentle
    case wise
    case energetic
    case calm

    var infoPlistKeys: [String] {
        switch self {
        case .cheerful:
            return ["ElevenLabsCheerfulVoiceID"]
        case .gentle:
            return ["ElevenLabsGentleVoiceID"]
        case .wise:
            return ["ElevenLabsWiseVoiceID"]
        case .energetic:
            return ["ElevenLabsEnergeticVoiceID"]
        case .calm:
            return ["ElevenLabsCalmVoiceID"]
        }
    }
}
