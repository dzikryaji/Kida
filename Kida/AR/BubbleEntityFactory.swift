//
//  BubbleEntityFactory.swift
//  Kida
//
//  Builds a 3D "speech bubble" entity -- a rounded background plate plus
//  extruded 3D text plus a small pointer/tail -- used to show what the
//  classifier thinks the tapped object is. Also owns the bubble's
//  slide+fade in/out animations, since "how a bubble appears/disappears"
//  is part of what makes it a bubble, not something the caller should
//  reimplement.
//
//  Plain-English primer: `MeshResource.generateText(...)` turns a Swift
//  string into an actual 3D mesh (letters with real depth, not a flat
//  picture of text), the same way `generateSphere`/`generateBox` turn
//  numbers into 3D shapes. `UnlitMaterial` is used instead of the eyes'
//  `SimpleMaterial` because unlit materials render at a flat, constant
//  brightness regardless of scene lighting -- important for text, which
//  needs to stay legible even in a dim room.
//

import CoreGraphics
import RealityKit
import UIKit

enum BubbleEntityFactory {

    static let fontSize: Float = 0.018
    static let extrusionDepth: Float = 0.002
    static let horizontalPadding: Float = 0.016
    static let verticalPadding: Float = 0.012
    static let cornerRadius: Float = 32.0
    static let textColor: UIColor = .black
    static let bubbleColor: UIColor = .white

    /// Builds the full bubble reading "Hi I'm a {objectLabel}", centered on
    /// its own local origin so the caller can freely position/anchor it.
    static func makeTextBubble(text message: String) -> Entity {
        let group = Entity()

        let textMesh = MeshResource.generateText(
            message,
            extrusionDepth: extrusionDepth,
            font: .systemFont(ofSize: CGFloat(fontSize)),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        let textBounds = textMesh.bounds

        let textEntity = ModelEntity(
            mesh: textMesh,
            materials: [UnlitMaterial(color: textColor)]
        )
        // `generateText` places its origin at the text block's bottom-left
        // corner, not its center, so re-center it around (0, 0) ourselves.
        textEntity.position = [
            -textBounds.center.x,
            -textBounds.center.y,
            extrusionDepth / 2 + 0.0005,  // sits just proud of the bubble background's front face
        ]

        let bubbleWidth = textBounds.extents.x + horizontalPadding
        let bubbleHeight = textBounds.extents.y + verticalPadding
        let bubbleDepth: Float = 0.002

        let bubbleMesh = MeshResource.generateBox(
            width: bubbleWidth,
            height: bubbleHeight,
            depth: bubbleDepth,
            cornerRadius: cornerRadius
        )
        let bubbleMaterial = UnlitMaterial(color: bubbleColor)
        let bubbleBackground = ModelEntity(
            mesh: bubbleMesh,
            materials: [bubbleMaterial]
        )

        // A small square, rotated 45 degrees and flattened, standing in as
        // the speech-bubble "tail" pointing down toward the object.
        let tailSize: Float = 0.012
        let tailMesh = MeshResource.generateBox(
            size: tailSize,
            cornerRadius: 0.001
        )
        let tail = ModelEntity(mesh: tailMesh, materials: [bubbleMaterial])
        tail.position = [0, -bubbleHeight / 2, 0]
        tail.transform.rotation = simd_quatf(angle: .pi / 4, axis: [0, 0, 1])
        tail.scale = [0.6, 0.6, 0.3]

        group.addChild(bubbleBackground)
        group.addChild(tail)
        group.addChild(textEntity)

        // Keep the whole bubble facing the camera, same as the eyes below it.
        group.components.set(BillboardComponent())

        return group
    }

    /// Slides the bubble up into `finalPosition` while fading it in from
    /// transparent. Callers are expected to have already parented the
    /// bubble and set its starting (offset, opacity-zero) state before
    /// calling this.
    static func animateIn(
        _ bubble: Entity,
        to finalPosition: SIMD3<Float>,
        duration: TimeInterval,
        timingFunction: AnimationTimingFunction = .easeOut
    ) {
        var target = bubble.transform
        target.translation = finalPosition
        bubble.move(to: target, relativeTo: bubble.parent, duration: duration, timingFunction: timingFunction)

        let fadeIn = FromToByAnimation<Float>(
            from: 0,
            to: 1,
            duration: duration,
            timing: timingFunction,
            bindTarget: .opacity
        )
        if let fadeInAnimation = try? AnimationResource.generate(with: fadeIn) {
            bubble.playAnimation(fadeInAnimation)
        }
    }

    /// Slides the bubble down by `offset` while fading it out, calling
    /// `completion` once the animation duration has elapsed. Does NOT
    /// remove the bubble from its parent -- that's an entity-graph/state
    /// decision left to the caller, done inside `completion`.
    static func animateOut(
        _ bubble: Entity,
        offset: SIMD3<Float>,
        duration: TimeInterval,
        timingFunction: AnimationTimingFunction = .easeIn,
        completion: (() -> Void)? = nil
    ) {
        var target = bubble.transform
        target.translation -= offset
        bubble.move(to: target, relativeTo: bubble.parent, duration: duration, timingFunction: timingFunction)

        let fadeOut = FromToByAnimation<Float>(
            from: 1,
            to: 0,
            duration: duration,
            timing: timingFunction,
            bindTarget: .opacity
        )
        if let fadeOutAnimation = try? AnimationResource.generate(with: fadeOut) {
            bubble.playAnimation(fadeOutAnimation)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            completion?()
        }
    }
}
