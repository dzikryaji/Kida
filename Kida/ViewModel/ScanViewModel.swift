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
import CoreImage
import UIKit

@MainActor
class ScanViewModel: ObservableObject {

    @Published private(set) var placedAnchor: AnchorEntity?
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var currentPersonality: FaceEntityFactory.Personality = .fancy
    @Published private(set) var currentExpression: FaceEntityFactory.Expression = .happy

    private let placementService: ARPlacementServicing
    private let segmenter: ObjectSegmenting

    // --- AI: persona (VLM + personality) + chat (Foundation Model) + voice (ElevenLabs) ---
    private let personaGenerator: PersonaGenerating = FoundationPersonaGenerator()
    private let understanding: VisualUnderstandingProviding = CascadingVisualUnderstandingProvider()
    private let voice = ObjectVoice()
    @Published private(set) var persona: ObjectPersona?
    @Published private(set) var isReplying = false
    private var history: [ChatMessage] = []
    private var capturedImage: UIImage?

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
        capturedImage = Self.image(from: pixelBuffer)

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

        // Decide the personality (VLM) FIRST, then build the face exactly once. Swapping the
        // personality after the face was already placed rebuilt it and stacked duplicate eyes.
        await setUpPersonaAndFace(on: anchor)
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

    // MARK: - AI persona + chat

    /// After placement: VLM understands the object → persona (personality + emotion) → apply the
    /// face personality, resting expression, greeting bubble, and spoken greeting. Falls back to a
    /// label-based persona when no VLM/Gemini is configured yet.
    /// After placement: VLM → persona → build the face ONCE with the right personality +
    /// resting expression, then show + speak the greeting. Building the face after the
    /// personality is known (rather than swapping it afterward) avoids the duplicate-face/eyes
    /// bug from tearing down and rebuilding an already-placed face.
    private func setUpPersonaAndFace(on anchor: AnchorEntity) async {
        let persona = await buildPersona(from: capturedImage)
        guard anchor === placedAnchor else { return }
        self.persona = persona
        history = []
        currentPersonality = persona.personalityKind.faceKind
        currentExpression = persona.emotionStyle.faceExpression
        await addFace(personality: currentPersonality, to: anchor, animated: true)
        addBubble(
            labeled: persona.greeting,
            to: anchor,
            afterDelay: faceAnimationDuration + bubbleAppearDelayAfterFace
        )
        Task { await self.voice.speak(persona.greeting, emotion: persona.emotionStyle, objectLabel: persona.objectLabel) }
    }

    /// VLM/Gemini understands the object → persona (personality + emotion). Falls back to a
    /// label-based persona when no VLM is configured.
    private func buildPersona(from image: UIImage?) async -> ObjectPersona {
        var detected = DetectedObject(
            label: "object", confidence: 0.5, capturedImage: image,
            boundingBox: nil, segmentation: nil, alternatives: [], visualContext: nil
        )
        var facts: RetrievedObjectFacts?
        if image != nil, let result = try? await understanding.makeObjectUnderstanding(for: detected) {
            detected.objectIntelligence = result.objectIntelligence
            detected.label = result.objectIntelligence.primaryLabel
            facts = result.retrievedFacts
        }
        var built = await personaGenerator.makePersona(for: detected)
        built.retrievedFacts = facts
        return built
    }

    /// Child sends a message → Foundation Model reply → bubble text + face expression + voice.
    func sendMessage(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let persona, !isReplying else { return }
        isReplying = true
        history.append(ChatMessage(role: .child, text: message, emotion: nil))
        Task {
            let reply = await self.personaGenerator.makeResponse(for: message, persona: persona, history: self.history)
            self.history.append(ChatMessage(role: .object, text: reply.text, emotion: reply.emotion))
            self.setBubbleText(reply.text)
            self.changeExpression(to: reply.emotion.faceExpression)
            self.isReplying = false
            await self.voice.speak(reply.text, emotion: reply.emotion, objectLabel: persona.objectLabel)
        }
    }

    /// Replaces the current bubble with a specific string (vs the hardcoded cycle).
    func setBubbleText(_ text: String) {
        guard let anchor = placedAnchor else { return }
        removeBubbleAnimated { [weak self, weak anchor] in
            guard let self, let anchor else { return }
            self.addBubble(labeled: text, to: anchor, afterDelay: 0)
        }
    }

    private static func image(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        // Camera buffer in a portrait app is .right-oriented; the AI's JPEG encoder bakes it upright.
        return UIImage(cgImage: cgImage, scale: 1, orientation: .right)
    }
}
