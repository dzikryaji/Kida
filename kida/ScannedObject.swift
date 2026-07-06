//
//  ScannedObject.swift
//  kida
//
//  The result of tapping an object: what it is, how it feels, and roughly how
//  far it looks — all estimated by the VLM. This is the value handed to the chat
//  and to the teammate's face layer.
//

import ARKit
import RealityKit
import UIKit

struct ScannedObject {
    let objectName: String            // from VLM, e.g. "mug"
    let estimatedDistance: Distance   // from VLM (rough estimate)
    let personality: Personality      // from VLM
}

enum Distance: String, CaseIterable {
    case near      // ~20 cm
    case middle    // ~40 cm
    case far       // ~60 cm+
}

enum Personality: String, CaseIterable {
    case smart, cool, fancy, feminine, careful

    /// One line injected into the chat system prompt so the object's replies
    /// match its personality.
    var promptStyle: String {
        switch self {
        case .smart:
            return "You are clever and curious, and you love sharing fun little facts in simple words."
        case .cool:
            return "You are laid-back, playful, and funny, like a cool best friend."
        case .fancy:
            return "You are elegant and a little fancy, and you use pretty, gentle words."
        case .feminine:
            return "You are sweet, warm, and gentle, and you speak softly and kindly."
        case .careful:
            return "You are careful and thoughtful, a little shy but very kind and caring."
        }
    }
}

extension VLMChatModel {

    /// Tap → one `ScannedObject`. Name, personality, and distance are all
    /// estimated by the VLM from a single cropped frame. Also returns that frame
    /// so the caller can hand the SAME image to `startChat` (no second capture).
    /// Returns nil if the capture or VLM fails.
    func scanObject(at tapPoint: CGPoint, in arView: ARView) async -> (object: ScannedObject, image: UIImage)? {
        // One silent frame, cropped to the tapped object, for the VLM to read.
        guard let image = FrameCapture.snapshot(
            from: arView, around: tapPoint, viewSize: arView.bounds.size
        ) else { return nil }

        guard let (name, personality, distance) = await identify(image: image) else { return nil }

        let object = ScannedObject(
            objectName: name,
            estimatedDistance: distance,
            personality: personality
        )
        return (object, image)
    }
}
