//
//  ScanViewModel.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 06/07/26.
//
//
//  Thin coordinator: holds published UI state and the bubble-text cycling
//  logic, and wires together SAM segmentation, ARPlacementService (placement
//  math), and the entity factories (building + animating eyes/bubbles).
//  Doesn't do raycasting or transform/animation math itself.
//

import ARKit
import RealityKit
import Combine
import CoreVideo

class ScanViewModel: ObservableObject {

    @Published private(set) var placedAnchor: AnchorEntity?
    @Published private(set) var isScanning: Bool = false

    private let placementService: ARPlacementServicing
    private let segmenter: ObjectSegmenting

    private weak var currentBubble: Entity?

    private let textBubbles = ["Hi im an object", "I can do this", "and do this", "love this"]
    private var textBubbleIndex = 0

    private let eyesAnimationDuration: TimeInterval = 0.3
    private let bubbleAnimationDuration: TimeInterval = 0.3
    private let bubbleAppearDelayAfterEyes: TimeInterval = 0.2
    private let bubbleSlideOffset: Float = 0.03
    private var bubbleYOffset: Float = 0.1

    init(
        placementService: ARPlacementServicing = ARPlacementService(),
        segmenter: ObjectSegmenting = SAM2ObjectSegmenter()
    ) {
        self.placementService = placementService
        self.segmenter = segmenter
    }

    /// Loads the SAM models. Call this once when the scan screen appears so
    /// the cost is paid up front instead of on the first tap.
    func warmUpSAM() async {
        await segmenter.prepare()
    }

    /// Entry point from the tap gesture. Runs SAM on the tapped point first;
    /// only once segmentation resolves do we raycast/place the AR object.
    /// `isScanning` stays true for exactly as long as segmentation takes -
    /// there's no artificial delay layered on top.
    func placeObject(
        at point: CGPoint,
        pixelBuffer: CVPixelBuffer,
        viewSize: CGSize,
        in arView: ARView
    ) {
        guard placedAnchor == nil, !isScanning else { return }

        isScanning = true

        let normalizedTap = SAMAnchorMath.normalizedTargetPoint(
            tapInView: point,
            viewSize: viewSize
        )

        Task { [weak self, weak arView] in
            guard let self else { return }

            let segmentation = await self.segmenter.segment(
                pixelBuffer: PixelBufferReference(value: pixelBuffer),
                targetPoint: normalizedTap,
                includePreview: false
            )

            await MainActor.run {
                self.isScanning = false

                guard let arView else { return }

                // Prefer the segmented object's centroid over the raw tap
                // point, since that's the actual object the child selected.
                // Fall back to the tap itself if SAM found nothing there.
                let anchorScreenPoint: CGPoint
                if let segmentation {
                    anchorScreenPoint = SAMAnchorMath.screenPoint(
                        fromNormalizedPoint: segmentation.centroid,
                        viewSize: viewSize
                    )
                } else {
                    print("SAM segmentation failed, falling back to raw tap point")
                    anchorScreenPoint = point
                }

                self.resolveAndFinalizePlacement(at: anchorScreenPoint, in: arView)
            }
        }
    }

    private func resolveAndFinalizePlacement(at screenPoint: CGPoint, in arView: ARView) {
        // Guard against a race where the placed object was removed (or
        // another placement started) while segmentation was running.
        guard placedAnchor == nil else { return }

        guard let placement = placementService.resolvePlacementTransform(for: screenPoint, in: arView) else {
            print("Could not resolve a placement, even with fallback")
            return
        }

        finalizePlacement(with: placement, in: arView)
    }

    private func finalizePlacement(with placement: simd_float4x4, in arView: ARView) {
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
