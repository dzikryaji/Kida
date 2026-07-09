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
// THIS IS THE NEW SCAN VIEW
import ARKit
import RealityKit
import Combine
import CoreVideo
import UIKit
import CoreImage

class ScanViewModel: ObservableObject {
    
    @Published private(set) var placedAnchor: AnchorEntity?
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var currentPersonality: FaceEntityFactory.Personality = .fancy
    @Published private(set) var currentExpression: FaceEntityFactory.Expression = .happy
    @Published private(set) var capturedImageData: Data?
    
    private let placementService: ARPlacementServicing
    private let segmenter: ObjectSegmenting
    
    private weak var currentFace: Entity?
    private weak var currentBubble: Entity?
    
    private let textBubbles = ["Hi im an object", "I can do this", "and do this", "love this"]
    private var textBubbleIndex = 0
    
    private let faceAnimationDuration: TimeInterval = 0.3
    private let bubbleAnimationDuration: TimeInterval = 0.3
    private let bubbleAppearDelayAfterFace: TimeInterval = 0.2
    private let bubbleSlideOffset: Float = 0.03
    private var bubbleYOffset: Float = 0.1
    
    init(
        placementService: ARPlacementServicing = ARPlacementService(),
        segmenter: ObjectSegmenting = SAM2ObjectSegmenter()
    ) {
        self.placementService = placementService
        self.segmenter = segmenter
        
        Task {
            await self.segmenter.prepare()
            await FaceEntityFactory.preloadBaseFace() 
        }
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
        
        // keep JPEG of the tapped frame so Save can persist it later
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        if let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) {
            capturedImageData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
        }
        
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
                
                Task {
                    await self.resolveAndFinalizePlacement(at: anchorScreenPoint, in: arView)
                    self.isScanning = false
                }
                
            }
        }
    }
    
    private func resolveAndFinalizePlacement(at screenPoint: CGPoint, in arView: ARView) async {
        // Guard against a race where the placed object was removed (or
        // another placement started) while segmentation was running.
        guard placedAnchor == nil else { return }
        
        guard let placement = placementService.resolvePlacementTransform(for: screenPoint, in: arView) else {
            print("Could not resolve a placement, even with fallback")
            return
        }
        
        await finalizePlacement(with: placement, in: arView)
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
        capturedImageData = nil
        
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
        guard expression != currentExpression else { return }
        
        currentExpression = expression
        
        guard let face = currentFace else { return }
        
        FaceEntityFactory.setExpression(
            expression,
            on: face,
            duration: 0.25
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
