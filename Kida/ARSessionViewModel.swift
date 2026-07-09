//
//  ARSessionViewModel.swift
//  DummyKida
//
//  Thin coordinator: holds published UI state and the bubble-text cycling
//  logic, and wires together ARPlacementService (placement math) and the
//  entity factories (building + animating the face/bubbles). Doesn't do
//  raycasting or transform/animation math itself.
//

import ARKit
import RealityKit
import Combine

@MainActor
class ARSessionViewModel: ObservableObject {

    @Published private(set) var placedAnchor: AnchorEntity?
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var currentPersonality: FaceEntityFactory.Personality = .boss
    @Published private(set) var currentExpression: FaceEntityFactory.Expression = .happy

    private let placementService: ARPlacementServicing = ARPlacementService()

    private weak var currentFace: Entity?
    private weak var currentBubble: Entity?
    

    private let textBubbles = ["Hi im an object", "I can do this", "and do this", "love this"]
    private var textBubbleIndex = 0

    private let scanningDuration: TimeInterval = 1.6
    private let faceAnimationDuration: TimeInterval = 0.3
    private let bubbleAnimationDuration: TimeInterval = 0.3
    private let bubbleAppearDelayAfterFace: TimeInterval = 0.2
    private let bubbleSlideOffset: Float = 0.03
    private let bubbleYOffset: Float = FaceEntityFactory.eyebrowVerticalOffset + 0.10

    init() {
        // Fire-and-forget: warm FaceEntityFactory's shared base-face
        // cache (eyes + eyebrows + mouth) as soon as the view model
        // exists, so it's likely already loaded by the time the user
        // actually taps to place -- at which point `addFace`/`makeFace`
        // only has to load that personality's own accessory.
        Task { await FaceEntityFactory.preloadBaseFace() }
    }

    func placeObject(at point: CGPoint, in arView: ARView) {
        guard placedAnchor == nil, !isScanning else { return }

        guard let placement = placementService.resolvePlacementTransform(for: point, in: arView) else {
            print("Could not resolve a placement, even with fallback")
            return
        }

        // Show a brief "scanning" overlay before the face actually pops
        // in, so placement feels like it's being analyzed rather than
        // instant.
        isScanning = true

        DispatchQueue.main.asyncAfter(deadline: .now() + scanningDuration) { [weak self, weak arView] in
            guard let self, let arView else { return }
            self.isScanning = false
            Task { await self.finalizePlacement(with: placement, in: arView) }
        }
    }

    private func finalizePlacement(with placement: simd_float4x4, in arView: ARView) async {
        // Guard against a race where the placed object was removed (or
        // another placement started) while we were "scanning".
        guard placedAnchor == nil else { return }

        let anchor = placementService.placeAnchor(at: placement, in: arView)
        placedAnchor = anchor

        await addFace(personality: currentPersonality, to: anchor, animated: true)

        textBubbleIndex = 0
        addBubble(
            labeled: textBubbles[textBubbleIndex],
            to: anchor,
            afterDelay: faceAnimationDuration + bubbleAppearDelayAfterFace
        )
    }

    func removePlacedObject() {
        guard let anchor = placedAnchor else { return }
        anchor.removeFromParent()
        placedAnchor = nil
        currentFace = nil
        currentBubble = nil
    }

    /// Swaps which personality's face is showing. If an object is already
    /// placed, the current face is torn down and the new one is built and
    /// popped in immediately. If nothing is placed yet, this just changes
    /// which personality the *next* placement will use.
    func changePersonality(to personality: FaceEntityFactory.Personality) {
        guard personality != currentPersonality else { return }
        currentPersonality = personality

        guard let anchor = placedAnchor else { return }

        currentFace?.removeFromParent()
        currentFace = nil

        Task { await addFace(personality: personality, to: anchor, animated: true) }
    }

    /// Loads the face for `personality` and attaches it to `anchor`.
    /// When `animated` is true the face starts scaled to near-zero and
    /// pops in via `FaceEntityFactory.popIn`, matching how the face is
    /// introduced on initial placement.
    private func addFace(personality: FaceEntityFactory.Personality, to anchor: AnchorEntity, animated: Bool) async {
        do {
            let face = try await FaceEntityFactory.makeFace(personality: personality)
            face.position = personality == .cautious  ? [0, -0.05, 0] : .zero
            face.scale = animated ? SIMD3<Float>(repeating: 0.01) : SIMD3<Float>(repeating: 1)

            // Guard against the object having been removed (or a newer
            // placement/personality change started) while the face was
            // loading asynchronously.
            guard anchor === placedAnchor else { return }

            anchor.addChild(face)
            currentFace = face
            
            FaceEntityFactory.setExpression(
                currentExpression,
                on: face,
                duration: 0
            )

            if animated {
                FaceEntityFactory.popIn(face, duration: faceAnimationDuration)
            }
            
            FaceEntityFactory.startBlinking(on: face)
        } catch {
            print("Failed to build face for personality \(personality.displayName): \(error)")
        }
    }
    
    func changeExpression(to expression: FaceEntityFactory.Expression) {
        let shouldAnimate = expression != currentExpression
        currentExpression = expression

        guard let face = currentFace else { return }

        FaceEntityFactory.setExpression(
            expression,
            on: face,
            duration: shouldAnimate ? 0.25 : 0
        )
    }

    private func addBubble(labeled label: String, to anchor: AnchorEntity, afterDelay delay: TimeInterval) {
        let bubble = BubbleEntityFactory.makeTextBubble(text: label)
        let finalPosition = SIMD3<Float>(0, bubbleYOffset, 0)
        bubble.position = finalPosition - SIMD3<Float>(0, bubbleSlideOffset, 0)
        bubble.components.set(OpacityComponent(opacity: 0))
        anchor.addChild(bubble)
        currentBubble = bubble

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak bubble] in
            guard let self, let bubble, bubble === self.currentBubble else { return }
            BubbleEntityFactory.animateIn(bubble, to: finalPosition, duration: self.bubbleAnimationDuration)
        }
    }

    func removeBubbleAnimated(completion: (() -> Void)? = nil) {
        guard let bubble = currentBubble else {
            completion?()
            return
        }

        BubbleEntityFactory.animateOut(
            bubble,
            offset: SIMD3<Float>(0, bubbleSlideOffset, 0),
            duration: bubbleAnimationDuration
        ) { [weak self, weak bubble] in
            bubble?.removeFromParent()
            if let self, self.currentBubble === bubble {
                self.currentBubble = nil
            }
            completion?()
        }
    }

    func replaceBubbleLabel() {
        guard let anchor = placedAnchor else { return }

        textBubbleIndex = (textBubbleIndex + 1) % textBubbles.count
        let newLabel = textBubbles[textBubbleIndex]

        removeBubbleAnimated { [weak self, weak anchor] in
            guard let self, let anchor else { return }
            self.addBubble(labeled: newLabel, to: anchor, afterDelay: 0)
        }
    }
}
