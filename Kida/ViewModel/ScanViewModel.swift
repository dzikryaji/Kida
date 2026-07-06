//
//  ScanViewModel.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 06/07/26.
//
//
//  Thin coordinator: holds published UI state and the bubble-text cycling
//  logic, and wires together ARPlacementService (placement math) and the
//  entity factories (building + animating eyes/bubbles). Doesn't do
//  raycasting or transform/animation math itself.
//

import ARKit
import RealityKit
import Combine

class ScanViewModel: ObservableObject {

    @Published private(set) var placedAnchor: AnchorEntity?
    @Published private(set) var isScanning: Bool = false

    private let placementService: ARPlacementServicing

    private weak var currentBubble: Entity?

    private let textBubbles = ["Hi im an object", "I can do this", "and do this", "love this"]
    private var textBubbleIndex = 0

    private let scanningDuration: TimeInterval = 1.6
    private let eyesAnimationDuration: TimeInterval = 0.3
    private let bubbleAnimationDuration: TimeInterval = 0.3
    private let bubbleAppearDelayAfterEyes: TimeInterval = 0.2
    private let bubbleSlideOffset: Float = 0.03
    private var bubbleYOffset: Float = 0.1

    init(placementService: ARPlacementServicing = ARPlacementService()) {
        self.placementService = placementService
    }

    func placeObject(at point: CGPoint, in arView: ARView) {
        guard placedAnchor == nil, !isScanning else { return }

        guard let placement = placementService.resolvePlacementTransform(for: point, in: arView) else {
            print("Could not resolve a placement, even with fallback")
            return
        }

        // Show a brief "scanning" overlay before the eyes actually pop in,
        // so placement feels like it's being analyzed rather than instant.
        isScanning = true

        DispatchQueue.main.asyncAfter(deadline: .now() + scanningDuration) { [weak self, weak arView] in
            guard let self, let arView else { return }
            self.isScanning = false
            self.finalizePlacement(with: placement, in: arView)
        }
    }

    private func finalizePlacement(with placement: simd_float4x4, in arView: ARView) {
        // Guard against a race where the placed object was removed (or
        // another placement started) while we were "scanning".
        guard placedAnchor == nil else { return }

        let anchor = placementService.placeAnchor(at: placement, in: arView)

        let eyes = EyeEntityFactory.makeEyePair()
        eyes.position = .zero
        eyes.scale = SIMD3<Float>(repeating: 0.01)
        anchor.addChild(eyes)
        placedAnchor = anchor

        EyeEntityFactory.popIn(eyes, duration: eyesAnimationDuration)

        textBubbleIndex = 0
        addBubble(
            labeled: textBubbles[textBubbleIndex],
            to: anchor,
            afterDelay: eyesAnimationDuration + bubbleAppearDelayAfterEyes
        )
    }

    func removePlacedObject() {
        guard let anchor = placedAnchor else { return }
        anchor.removeFromParent()
        placedAnchor = nil
        currentBubble = nil
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


