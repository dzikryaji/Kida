//
//  BubbleEntityFactory.swift
//  Kida
//
//  Builds a 3D "speech bubble" entity -- a rounded, semi-transparent
//  gradient-filled background plate plus extruded 3D text plus a small
//  pointer/tail -- used to show what the classifier thinks the tapped
//  object is. Also owns the bubble's slide+fade in/out animations, since
//  "how a bubble appears/disappears" is part of what makes it a bubble,
//  not something the caller should reimplement.
//
//  Visual language matches the 2D `SpeechBubble` SwiftUI view's "system"
//  style -- same gold gradient, same dark text -- just expressed in
//  RealityKit terms instead of SwiftUI ones. The background plate is a
//  true pill/stadium shape (fully rounded ends) and renders
//  semi-transparent so it doesn't fully occlude whatever real-world
//  object it's pointing at.
//
//  Plain-English primer: `MeshResource.generateText(...)` turns a Swift
//  string into an actual 3D mesh (letters with real depth, not a flat
//  picture of text), the same way `generateSphere`/`generateBox` turn
//  numbers into 3D shapes. `UnlitMaterial` is used instead of the eyes'
//  `SimpleMaterial` because unlit materials render at a flat, constant
//  brightness regardless of scene lighting -- important for text, which
//  needs to stay legible even in a dim room. RealityKit materials don't
//  support gradients out of the box, so the gradient fill below is done
//  by rendering a tiny top-to-bottom gradient image with Core Graphics
//  and using that as the material's texture. Transparency on an
//  `UnlitMaterial` also requires explicitly opting into `.transparent`
//  blending -- alpha in the color/texture is otherwise ignored.
//
//  Background shape note: the plate uses `generatePlane(width:height:
//  cornerRadius:)`, not `generateBox`. A box's corner radius gets
//  clamped relative to its *smallest* dimension across all three axes --
//  with a paper-thin depth like this plate's, that clamp effectively
//  zeroes out any rounding no matter how large a value is requested. A
//  plane has no depth axis to clamp against, so the requested radius is
//  honored in full, which is what actually produces a pill shape.
//

import CoreGraphics
import RealityKit
import UIKit

enum BubbleEntityFactory {

    // MARK: - Palette (kept in step with ChatStyle in the 2D chat UI)

    static let fillTop: UIColor    = UIColor(red: 0.953, green: 0.788, blue: 0.412, alpha: 1) // #F3C969
    static let fillBottom: UIColor = UIColor(red: 0.878, green: 0.659, blue: 0.243, alpha: 1) // #E0A83E
    static let textColor: UIColor  = UIColor(red: 0.290, green: 0.231, blue: 0.122, alpha: 1) // #4A3B1F

    static let fontSize: Float = 0.018
    static let extrusionDepth: Float = 0.002
    static let horizontalPadding: Float = 0.028   // extra roomy so short text still reads as a pill, not a circle
    static let verticalPadding: Float = 0.012

    /// Alpha applied to the bubble background (and tail) only -- text
    /// stays fully opaque so it's always legible over whatever real-world
    /// surface is showing through the semi-transparent plate.
    static let backgroundOpacity: Float = 0.7

    /// Widest a bubble is allowed to get before text wraps onto a new
    /// line, in meters. `generateText` only wraps at all if given a
    /// non-zero container width to wrap against -- a `.zero` containerFrame
    /// disables wrapping no matter what `lineBreakMode` is set to, so this
    /// is what actually makes wrapping happen, not just an aesthetic knob.
    static let maxTextWidth: Float = 0.24

    /// Builds the full bubble reading "Hi I'm a {objectLabel}", centered on
    /// its own local origin so the caller can freely position/anchor it.
    /// Long text wraps onto additional lines (growing the bubble downward)
    /// instead of stretching the bubble wider than `maxTextWidth`.
    static func makeTextBubble(text message: String) -> Entity {
        let group = Entity()

        // A generously tall container so wrapped lines always fit --
        // only the width is a real constraint here, height is just "big
        // enough to never clip."
        let containerFrame = CGRect(
            x: 0, y: 0,
            width: CGFloat(maxTextWidth),
            height: CGFloat(maxTextWidth) * 4
        )

        let textMesh = MeshResource.generateText(
            message,
            extrusionDepth: extrusionDepth,
            font: .systemFont(ofSize: CGFloat(fontSize)),
            containerFrame: containerFrame,
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
        // Note this re-centers on the *actual* wrapped extents (from
        // textBounds), not on `containerFrame`, so short one-line
        // messages still sit centered rather than left-aligned inside
        // the wider container box.
        textEntity.position = [
            -textBounds.center.x,
            -textBounds.center.y,
            extrusionDepth / 2 + 0.0005,  // sits just proud of the bubble background's front face
        ]

        // Bubble sizes itself to the *wrapped* text extents, so it grows
        // down (taller) for long messages rather than out (wider) --
        // width is naturally capped near maxTextWidth once wrapping kicks in.
        let bubbleWidth = textBounds.extents.x + horizontalPadding
        let bubbleHeight = textBounds.extents.y + verticalPadding

        // True pill/stadium shape: corner radius = half the height, so
        // both ends are fully rounded semicircles. `generatePlane` honors
        // this in full since (unlike `generateBox`) there's no depth axis
        // for the radius to get clamped against.
        let cornerRadius = bubbleHeight / 2

        let fillMaterial = gradientMaterial()

        // `generatePlane(width:height:cornerRadius:)` -- the two-parameter
        // (width/height, not width/depth) overload -- builds a flat plane
        // facing along +Z, i.e. already oriented like a vertical card
        // facing the camera, which is exactly what a billboarded
        // background plate needs.
        let bubbleMesh = MeshResource.generatePlane(
            width: bubbleWidth,
            height: bubbleHeight,
            cornerRadius: cornerRadius
        )
        let bubbleBackground = ModelEntity(mesh: bubbleMesh, materials: [fillMaterial])

        // A small square, rotated 45 degrees and flattened, standing in as
        // the speech-bubble "tail" pointing down toward the object. Reuses
        // `fillMaterial` so it automatically matches the background's
        // gradient and transparency.
        let tailSize: Float = 0.012
        let tailMesh = MeshResource.generateBox(size: tailSize, cornerRadius: 0.001)
        let tail = ModelEntity(mesh: tailMesh, materials: [fillMaterial])
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

    // MARK: - Gradient fill

    /// Builds an `UnlitMaterial` whose base color is a small top-to-bottom
    /// gradient texture, matching `ChatStyle`'s `LinearGradient(startPoint:
    /// .top, endPoint: .bottom)` for the system bubble, rendered at
    /// `backgroundOpacity`. Falls back to a flat, semi-transparent
    /// mid-tone if texture generation ever fails, so a bubble is never
    /// left uncolored.
    private static func gradientMaterial() -> UnlitMaterial {
        var material = UnlitMaterial()

        // Without this, alpha in the color/texture below is ignored and
        // the bubble renders fully opaque regardless of alpha values.
        material.blending = .transparent(opacity: .init(floatLiteral: 1.0))

        if let texture = gradientTexture(top: fillTop, bottom: fillBottom) {
            material.color = .init(
                tint: .white.withAlphaComponent(CGFloat(backgroundOpacity)),
                texture: .init(texture)
            )
        } else {
            material.color = .init(tint: fillBottom.withAlphaComponent(CGFloat(backgroundOpacity)))
        }
        return material
    }

    /// Renders a thin vertical gradient strip (top color -> bottom color)
    /// and wraps it as a `TextureResource`. A narrow, short image is all
    /// that's needed since it's stretched across a flat plate face.
    /// Alpha is baked directly into the gradient stops (not just applied
    /// via the material's tint) so the texture itself is genuinely
    /// semi-transparent.
    private static func gradientTexture(
        top: UIColor,
        bottom: UIColor,
        size: CGSize = CGSize(width: 4, height: 64)
    ) -> TextureResource? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let alpha = CGFloat(backgroundOpacity)
            guard let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    top.withAlphaComponent(alpha).cgColor,
                    bottom.withAlphaComponent(alpha).cgColor
                ] as CFArray,
                locations: [0, 1]
            ) else { return }

            // Clear first -- UIGraphicsImageRenderer defaults to an
            // opaque backing otherwise, which would flatten our alpha
            // gradient onto solid white before it ever reaches the GPU.
            context.cgContext.clear(CGRect(origin: .zero, size: size))
            context.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: size.width / 2, y: 0),
                end: CGPoint(x: size.width / 2, y: size.height),
                options: []
            )
        }

        return try? TextureResource(image: image as! CGImage, options: .init(semantic: .color))
    }

    // MARK: - Animation (unchanged)

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

