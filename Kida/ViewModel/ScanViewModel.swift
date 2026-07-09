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
    @Published private(set) var currentPersonality: FaceEntityFactory.Personality = .caregiver
    @Published private(set) var currentExpression: FaceEntityFactory.Expression = .sad
    @Published private(set) var capturedImageData: Data?

    private let placementService: ARPlacementServicing
    private let segmenter: ObjectSegmenting

    // --- AI: persona (VLM + personality) + chat (Foundation Model) + voice (ElevenLabs) ---
    private let personaGenerator: PersonaGenerating = FoundationPersonaGenerator()
    private let understanding: VisualUnderstandingProviding = CascadingVisualUnderstandingProvider()
    private let voice = ObjectVoice()
    @Published private(set) var persona: ObjectPersona?
    @Published private(set) var isReplying = false
    @Published private(set) var isUnderstandingObject = false
    private var history: [ChatMessage] = []
    private var capturedImage: UIImage?

    private weak var currentFace: Entity?
    private weak var currentBubble: Entity?
    private weak var currentPresentation: Entity?
    private var currentFaceHasPersonalityAccessory = false
    private var faceBuildGeneration = 0
    private var personaBuildGeneration = 0
    private var thinkingBubbleTask: Task<Void, Never>?

    private let textBubbles = ["Hi im an object", "I can do this", "and do this", "love this"]
    private var textBubbleIndex = 0

    private let faceAnimationDuration: TimeInterval = 0.3
    private let bubbleAnimationDuration: TimeInterval = 0.3
    private let bubbleAppearDelayAfterFace: TimeInterval = 0.2
    private let bubbleSlideOffset: Float = 0.03
    private let bubbleYOffset: Float = FaceEntityFactory.eyebrowVerticalOffset + 0.10
    private let bubbleZOffset: Float = 0.025
    private static let presentationEntityName = "kida.faceAndBubblePresentation"
    private static let faceEntityName = "kida.face"

    var collectionItemName: String {
        let rawName = persona?.objectLabel ?? persona?.name ?? "object"
        let cleaned = rawName
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return "Object" }
        return cleaned
            .split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    var collectionItemDescription: String {
        guard let persona else {
            return "A scanned object from Kida."
        }

        var parts: [String] = []
        let greeting = persona.greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        if !greeting.isEmpty {
            parts.append(greeting)
        }

        let facts = persona.kidFriendlyFacts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
        if !facts.isEmpty {
            parts.append(facts.joined(separator: " "))
        }

        let visualSummary = persona.objectIntelligence?.visualSummary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let visualSummary, !visualSummary.isEmpty {
            parts.append(visualSummary)
        }

        return parts.isEmpty ? "A scanned \(collectionItemName) from Kida." : parts.joined(separator: "\n\n")
    }

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

    /// Entry point from the tap gesture. Runs SAM on the fixed center guide first;
    /// only once segmentation resolves do we raycast/place the AR object.
    /// `isScanning` stays true for exactly as long as segmentation takes -
    /// there's no artificial delay layered on top.
    func placeObject(
        at point: CGPoint,
        pixelBuffer: CVPixelBuffer,
        viewSize: CGSize,
        in arView: ARView
    ) {
        guard placedAnchor == nil, !isScanning, !isUnderstandingObject else { return }

        isScanning = true
        capturedImage = Self.image(from: pixelBuffer)
        capturedImageData = capturedImage?.jpegData(compressionQuality: 0.82)

        let normalizedGuideCenter = SAMAnchorMath.normalizedTargetPoint(
            tapInView: point,
            viewSize: viewSize
        )

        Task { [weak self, weak arView] in
            guard let self else { return }

            let segmentation = await self.segmenter.segment(
                pixelBuffer: PixelBufferReference(value: pixelBuffer),
                targetPoint: normalizedGuideCenter,
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
                    print("SAM segmentation failed, falling back to center guide point")
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

        // Put the face on screen immediately. The slow VLM pass enriches the
        // persona afterward and animates the expression/personality update.
        await setUpPersonaAndFace(on: anchor)
    }

    func removePlacedObject() {
        guard let anchor = placedAnchor else { return }
        faceBuildGeneration += 1
        personaBuildGeneration += 1
        if let currentFace {
            FaceEntityFactory.stopAnimations(for: currentFace)
        }
        stopThinkingBubbleAnimation()
        anchor.removeFromParent()
        placedAnchor = nil
        currentFace = nil
        currentBubble = nil
        currentPresentation = nil
        currentFaceHasPersonalityAccessory = false
        persona = nil
        history = []
        capturedImage = nil
        capturedImageData = nil
        isReplying = false
        isUnderstandingObject = false
    }

    /// Swaps which personality's face is showing. If an object is already
    /// placed, the current face is torn down and the new one is built and
    /// popped in immediately. If nothing is placed yet, this just changes
    /// which personality the *next* placement will use.
    func changePersonality(to personality: FaceEntityFactory.Personality) {
        guard personality != currentPersonality else { return }
        currentPersonality = personality

        guard let anchor = placedAnchor else { return }

        if let currentFace {
            FaceEntityFactory.stopAnimations(for: currentFace)
        }
        let presentation = presentationEntity(for: anchor)
        removeExistingFaces(from: presentation, under: anchor)
        currentFace = nil

        Task { await addPersonalityFace(personality: personality, to: anchor, animated: true) }
    }

    /// Loads the face for `personality` and attaches it to `anchor`.
    /// When `animated` is true the face starts scaled to near-zero and
    /// pops in via `FaceEntityFactory.popIn`, matching how the face is
    /// introduced on initial placement.
    private func addNeutralFace(to anchor: AnchorEntity, animated: Bool) async {
        await addFace(personality: nil, to: anchor, animated: animated)
    }

    private func addPersonalityFace(personality: FaceEntityFactory.Personality, to anchor: AnchorEntity, animated: Bool) async {
        await addFace(personality: personality, to: anchor, animated: animated)
    }

    private func addFace(personality: FaceEntityFactory.Personality?, to anchor: AnchorEntity, animated: Bool) async {
        faceBuildGeneration += 1
        let generation = faceBuildGeneration

        do {
            let face: Entity
            if let personality {
                face = try await FaceEntityFactory.makeFace(personality: personality)
            } else {
                face = try await FaceEntityFactory.makeBaseFace()
            }
            face.position = personality == .cautious ? [0, -0.05, 0] : .zero
            face.scale = animated ? SIMD3<Float>(repeating: 0.01) : SIMD3<Float>(repeating: 1)

            // Guard against the object having been removed (or a newer
            // placement/personality change started) while the face was
            // loading asynchronously.
            guard anchor === placedAnchor,
                  generation == faceBuildGeneration,
                  personality == nil || personality == currentPersonality
            else { return }

            let presentation = presentationEntity(for: anchor)
            removeExistingFaces(from: presentation, under: anchor)

            face.name = Self.faceEntityName
            presentation.addChild(face)
            currentFace = face
            currentFaceHasPersonalityAccessory = personality != nil
            
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
            let faceDescription = personality?.displayName ?? "neutral base face"
            print("Failed to build face for \(faceDescription): \(error)")
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
        let finalPosition = bubbleFinalPosition()
        bubble.position = finalPosition - SIMD3<Float>(0, bubbleSlideOffset, 0)
        bubble.components.set(OpacityComponent(opacity: 0))
        presentationEntity(for: anchor).addChild(bubble)
        currentBubble = bubble

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak bubble] in
            guard let self, let bubble, bubble === self.currentBubble else { return }
            BubbleEntityFactory.animateIn(bubble, to: finalPosition, duration: self.bubbleAnimationDuration)
        }
    }

    private func bubbleFinalPosition() -> SIMD3<Float> {
        SIMD3<Float>(0, bubbleYOffset, bubbleZOffset)
    }

    private func replaceBubbleInstantly(labeled label: String, to anchor: AnchorEntity) {
        currentBubble?.removeFromParent()

        let bubble = BubbleEntityFactory.makeTextBubble(text: label)
        bubble.position = bubbleFinalPosition()
        bubble.components.set(OpacityComponent(opacity: 1))
        presentationEntity(for: anchor).addChild(bubble)
        currentBubble = bubble
    }

    private func startThinkingBubbleAnimation(on anchor: AnchorEntity, afterDelay delay: TimeInterval) {
        stopThinkingBubbleAnimation()

        let generation = personaBuildGeneration
        let labels = ["Thinking", "Thinking.", "Thinking..", "Thinking..."]
        thinkingBubbleTask = Task { [weak self, weak anchor] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            var index = 0
            guard let self,
                  let anchor,
                  anchor === self.placedAnchor,
                  generation == self.personaBuildGeneration,
                  self.isUnderstandingObject
            else { return }

            self.addBubble(labeled: labels[index], to: anchor, afterDelay: 0)
            index = (index + 1) % labels.count

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 420_000_000)
                guard anchor === self.placedAnchor,
                      generation == self.personaBuildGeneration,
                      self.isUnderstandingObject
                else { return }

                self.replaceBubbleInstantly(labeled: labels[index], to: anchor)
                index = (index + 1) % labels.count
            }
        }
    }

    private func stopThinkingBubbleAnimation() {
        thinkingBubbleTask?.cancel()
        thinkingBubbleTask = nil
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

    /// Single AR child under the placement anchor that owns the whole visible
    /// character. The face and bubble remain independent children so their
    /// factories can still animate/update them normally.
    private func presentationEntity(for anchor: AnchorEntity) -> Entity {
        if let currentPresentation,
           currentPresentation.parent === anchor {
            return currentPresentation
        }

        if let existing = anchor.findEntity(named: Self.presentationEntityName) {
            currentPresentation = existing
            return existing
        }

        let presentation = Entity()
        presentation.name = Self.presentationEntityName
        anchor.addChild(presentation)
        currentPresentation = presentation
        return presentation
    }

    /// Remove every old face from the shared presentation entity before
    /// installing a new one. This avoids duplicate eyes if an async rebuild
    /// outlives the weak `currentFace` reference or if an older unnamed face
    /// is still attached from a previous replacement path.
    private func removeExistingFaces(from presentation: Entity, under anchor: AnchorEntity) {
        if let currentFace {
            FaceEntityFactory.stopAnimations(for: currentFace)
            currentFace.removeFromParent()
        }

        for child in Array(anchor.children)
        where child.name != Self.presentationEntityName && isFaceEntity(child) {
            FaceEntityFactory.stopAnimations(for: child)
            child.removeFromParent()
        }

        for child in Array(presentation.children) where isFaceEntity(child) {
            FaceEntityFactory.stopAnimations(for: child)
            child.removeFromParent()
        }

        currentFace = nil
        currentFaceHasPersonalityAccessory = false
    }

    private func isFaceEntity(_ entity: Entity) -> Bool {
        entity.name == Self.faceEntityName
            || entity.findEntity(named: "eyes") != nil
            || entity.findEntity(named: "eyebrows") != nil
            || entity.findEntity(named: "mouth") != nil
    }

    // MARK: - AI persona + chat

    /// After placement: show an immediate default face + thinking bubble, then let the
    /// VLM/Foundation persona arrive in the background and update the same object.
    private func setUpPersonaAndFace(on anchor: AnchorEntity) async {
        personaBuildGeneration += 1
        let generation = personaBuildGeneration
        let image = capturedImage
        let thinkingPersona = makeThinkingPersona()

        isUnderstandingObject = true
        persona = thinkingPersona
        history = []
        currentExpression = thinkingPersona.emotionStyle.faceExpression
        await addNeutralFace(to: anchor, animated: true)

        guard anchor === placedAnchor, generation == personaBuildGeneration else { return }
        startThinkingBubbleAnimation(
            on: anchor,
            afterDelay: faceAnimationDuration + bubbleAppearDelayAfterFace
        )

        Task { [weak self, weak anchor] in
            guard let self else { return }
            let resolvedPersona = await self.buildPersona(from: image)
            guard let anchor,
                  anchor === self.placedAnchor,
                  generation == self.personaBuildGeneration
            else { return }

            await self.applyResolvedPersona(resolvedPersona, on: anchor)
        }
    }

    private func makeThinkingPersona() -> ObjectPersona {
        ObjectPersona(
            name: "Kida Object",
            objectLabel: "object",
            personality: "curious and upbeat while studying the object",
            personalityKind: .cool,
            voiceProfile: .cheerful,
            voiceGender: .woman,
            voiceFamily: .bright,
            emotionStyle: .happy,
            greeting: "Thinking",
            kidFriendlyFacts: ["I am looking at the whole camera frame before I answer."],
            visualContext: "Waiting for Qwen3 vision understanding."
        )
    }

    private func applyResolvedPersona(_ resolvedPersona: ObjectPersona, on anchor: AnchorEntity) async {
        stopThinkingBubbleAnimation()
        persona = resolvedPersona
        history = []
        isUnderstandingObject = false

        let resolvedPersonality = resolvedPersona.personalityKind.faceKind
        let resolvedExpression = resolvedPersona.emotionStyle.faceExpression

        AIDebugLogger.trace("VLM visual persona update", """
        personality=\(resolvedPersona.personalityKind.rawValue)
        emotion=\(resolvedPersona.emotionStyle.rawValue)
        faceExpression=\(resolvedExpression.displayName)
        """)

        if !currentFaceHasPersonalityAccessory || resolvedPersonality != currentPersonality {
            currentPersonality = resolvedPersonality
            await addPersonalityFace(personality: resolvedPersonality, to: anchor, animated: true)
        }

        let preparedSpeech = await voice.prepareSpeech(
            resolvedPersona.greeting,
            emotion: resolvedPersona.emotionStyle,
            persona: resolvedPersona
        )
        changeExpression(to: resolvedExpression)
        setBubbleText(resolvedPersona.greeting)
        voice.play(preparedSpeech)
    }

    /// VLM/Gemini understands the object → persona (personality + emotion). Falls back to a
    /// label-based persona when no VLM is configured.
    private func buildPersona(from image: UIImage?) async -> ObjectPersona {
        var detected = DetectedObject(
            label: "object", confidence: 0.5, capturedImage: image,
            boundingBox: nil, segmentation: nil, alternatives: [], visualContext: nil
        )
        var facts: RetrievedObjectFacts?
        AIDebugLogger.trace("VLM request summary", """
        imageAvailable=\(image != nil)
        providerAvailable=\(understanding.isAvailable)
        labelHint=\(detected.label)
        confidenceHint=\(detected.confidence)
        """)
        if image != nil {
            do {
                let result = try await understanding.makeObjectUnderstanding(for: detected)
                detected.objectIntelligence = result.objectIntelligence
                detected.label = result.objectIntelligence.primaryLabel
                facts = result.retrievedFacts
                AIDebugLogger.trace("VLM response source", result.source ?? "unknown")
                AIDebugLogger.json("VLM object card", result.objectIntelligence)
                if let retrievedFacts = result.retrievedFacts {
                    AIDebugLogger.json("VLM retrieved facts", retrievedFacts)
                } else {
                    AIDebugLogger.trace("VLM retrieved facts", "none returned by provider")
                }
            } catch {
                AIDebugLogger.trace("VLM failed", String(describing: error))
            }
        }
        if facts == nil {
            facts = ObjectFactStore().retrieve(for: detected)
            if let facts {
                AIDebugLogger.json("Local facts fallback", facts)
            }
        }
        var built = await personaGenerator.makePersona(for: detected)
        built.objectIntelligence = detected.objectIntelligence
        built.retrievedFacts = facts
        AIDebugLogger.json("Final persona for chat", built)
        return built
    }

    /// Child sends a message → Foundation Model reply → bubble text + face expression + voice.
    func sendMessage(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let persona, !isReplying, !isUnderstandingObject else { return }
        isReplying = true
        let priorHistory = history
        history.append(ChatMessage(role: .child, text: message, emotion: nil))
        AIDebugLogger.trace("Chat history before response", """
        priorMessages=\(priorHistory.count)
        totalAfterChild=\(history.count)
        childMessage=\(message)
        """)
        Task {
            let reply = await self.personaGenerator.makeResponse(for: message, persona: persona, history: priorHistory)
            self.history.append(ChatMessage(
                role: .object,
                text: reply.text,
                emotion: reply.emotion,
                grounded: reply.grounded,
                usedFacts: reply.usedFacts ?? []
            ))
            AIDebugLogger.trace("Chat history after response", """
            totalMessages=\(self.history.count)
            objectUsedFacts=\((reply.usedFacts ?? []).joined(separator: " | "))
            """)
            AIDebugLogger.trace("Chat visual update", """
            emotion=\(reply.emotion.rawValue)
            faceExpression=\(reply.emotion.faceExpression.displayName)
            mouthAnimationMode=\(reply.mouthAnimationMode.rawValue)
            """)
            let preparedSpeech = await self.voice.prepareSpeech(reply.text, emotion: reply.emotion, persona: persona)
            self.setBubbleText(reply.text)
            self.changeExpression(to: reply.emotion.faceExpression)
            self.voice.play(preparedSpeech)
            self.isReplying = false
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
