////
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
    @Published private(set) var currentPersonality: CharacterEntityFactory.Personality = .caregiver
    @Published private(set) var currentExpression: CharacterEntityFactory.Expression = .sad
    @Published private(set) var capturedImageData: Data?
    @Published private(set) var capturedStickerImageData: Data?

    private let placementService: ARPlacementServicing
    private let segmenter: ObjectSegmenting

    // --- AI: persona (VLM + personality) + chat (Foundation Model) + voice (ElevenLabs) ---
    private let personaGenerator: PersonaGenerating = FoundationPersonaGenerator()
    private let understanding: VisualUnderstandingProviding = CascadingVisualUnderstandingProvider()
    private let stickerService = StickerService()
    private let voice = ObjectVoice()
    @Published private(set) var persona: ObjectPersona?
    @Published private(set) var isReplying = false
    @Published private(set) var isUnderstandingObject = false
    private var history: [ChatMessage] = []
    private var capturedImage: UIImage?
    private var capturedSegmentation: ObjectSegmentation?

    private weak var currentFace: Entity?
    private weak var currentBubble: Entity?
    /// The one entity that owns both the face and the bubble for the
    /// currently placed object -- see `CharacterEntityFactory`. Replaces
    /// the old `currentPresentation`, which parented face and bubble as
    /// two independently-billboarded siblings rather than as parts of a
    /// single character.
    private weak var currentCharacter: Entity?
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
    private let bubbleYOffset: Float = CharacterEntityFactory.eyebrowVerticalOffset + 0.10
    private let bubbleZOffset: Float = 0.025

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
            await CharacterEntityFactory.preloadBaseFace()
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
        capturedStickerImageData = nil
        capturedSegmentation = nil

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
                self.capturedSegmentation = segmentation

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
            CharacterEntityFactory.stopAnimations(for: currentFace)
        }
        stopThinkingBubbleAnimation()
        anchor.removeFromParent()
        placedAnchor = nil
        currentFace = nil
        currentBubble = nil
        currentCharacter = nil
        currentFaceHasPersonalityAccessory = false
        persona = nil
        history = []
        capturedImage = nil
        capturedSegmentation = nil
        capturedImageData = nil
        capturedStickerImageData = nil
        isReplying = false
        isUnderstandingObject = false
    }

    func makeCollectionStickerData() async -> Data? {
        if let capturedStickerImageData {
            return capturedStickerImageData
        }

        guard let capturedImage else {
            AIDebugLogger.trace("Collection sticker request", "No captured image available")
            return nil
        }

        AIDebugLogger.trace("Collection sticker request", """
        imageAvailable=true
        segmentationAvailable=\(capturedSegmentation != nil)
        """)

        guard let sticker = await stickerService.makeSticker(
            from: capturedImage,
            targetBox: capturedSegmentation?.boundingBox,
            focusPoint: capturedSegmentation?.centroid
        ),
              let data = sticker.pngData()
        else {
            AIDebugLogger.trace("Collection sticker response", "No sticker returned; saving raw image only")
            return nil
        }

        capturedStickerImageData = data
        AIDebugLogger.trace("Collection sticker response", "bytes=\(data.count)")
        return data
    }

    /// Swaps which personality's face is showing. If an object is already
    /// placed, the current face is torn down and the new one is built and
    /// popped in immediately. If nothing is placed yet, this just changes
    /// which personality the *next* placement will use.
    func changePersonality(to personality: CharacterEntityFactory.Personality) {
        guard personality != currentPersonality else { return }
        currentPersonality = personality

        guard let anchor = placedAnchor else { return }

        // Stop the old face's blink loop right away rather than waiting
        // for the new face to finish loading -- `addFace` below will
        // swap the actual entity out (via `attachFace`, which itself
        // stops animations on whatever it replaces) once it's ready.
        if let currentFace {
            CharacterEntityFactory.stopAnimations(for: currentFace)
        }

        Task { await addPersonalityFace(personality: personality, to: anchor, animated: true) }
    }

    /// Loads the face for `personality` and attaches it to `anchor`.
    /// When `animated` is true the face starts scaled to near-zero and
    /// pops in via `CharacterEntityFactory.popIn`, matching how the face
    /// is introduced on initial placement.
    private func addNeutralFace(to anchor: AnchorEntity, animated: Bool) async {
        await addFace(personality: nil, to: anchor, animated: animated)
    }

    private func addPersonalityFace(personality: CharacterEntityFactory.Personality, to anchor: AnchorEntity, animated: Bool) async {
        await addFace(personality: personality, to: anchor, animated: animated)
    }

    private func addFace(personality: CharacterEntityFactory.Personality?, to anchor: AnchorEntity, animated: Bool) async {
        faceBuildGeneration += 1
        let generation = faceBuildGeneration

        do {
            let face: Entity
            if let personality {
                face = try await CharacterEntityFactory.makeFace(personality: personality)
            } else {
                face = try await CharacterEntityFactory.makeBaseFace()
            }
            face.position = personality == .cautious ? [0, -0.05, 0] : .zero
            face.scale = animated ? SIMD3<Float>(repeating: 0.01) : SIMD3<Float>(repeating: 1)
            if animated, let personality {
                CharacterEntityFactory.prepareAccessoryForWearAnimation(on: face, personality: personality)
            }

            // Guard against the object having been removed (or a newer
            // placement/personality change started) while the face was
            // loading asynchronously.
            guard anchor === placedAnchor,
                  generation == faceBuildGeneration,
                  personality == nil || personality == currentPersonality
            else { return }

            // Attach onto the single character entity for this anchor.
            // `attachFace` replaces whatever face was there before (and
            // stops its animations) without touching any bubble that
            // happens to be mid fade-in/out alongside it.
            let character = characterEntity(for: anchor)
            CharacterEntityFactory.attachFace(face, to: character)
            currentFace = face
            currentFaceHasPersonalityAccessory = personality != nil

            CharacterEntityFactory.setExpression(
                currentExpression,
                on: face,
                duration: 0
            )

            if animated {
                CharacterEntityFactory.popIn(face, duration: faceAnimationDuration)
                if let personality {
                    CharacterEntityFactory.wearAccessory(on: face, personality: personality)
                }
            }

            CharacterEntityFactory.startBlinking(on: face)
        } catch {
            let faceDescription = personality?.displayName ?? "neutral base face"
            print("Failed to build face for \(faceDescription): \(error)")
        }
    }

    func changeExpression(to expression: CharacterEntityFactory.Expression) {
        let shouldAnimate = expression != currentExpression
        currentExpression = expression

        guard let face = currentFace else { return }

        CharacterEntityFactory.setExpression(
            expression,
            on: face,
            duration: shouldAnimate ? 0.25 : 0
        )
    }

    private func addBubble(labeled label: String, to anchor: AnchorEntity, afterDelay delay: TimeInterval) {
        let bubble = CharacterEntityFactory.makeTextBubble(text: label)
        let finalPosition = bubbleFinalPosition()
        bubble.position = finalPosition - SIMD3<Float>(0, bubbleSlideOffset, 0)
        bubble.components.set(OpacityComponent(opacity: 0))
        let character = characterEntity(for: anchor)
        CharacterEntityFactory.attachBubble(bubble, to: character)
        currentBubble = bubble

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak bubble] in
            guard let self, let bubble, bubble === self.currentBubble else { return }
            CharacterEntityFactory.animateIn(bubble, to: finalPosition, duration: self.bubbleAnimationDuration)
        }
    }

    private func bubbleFinalPosition() -> SIMD3<Float> {
        SIMD3<Float>(0, bubbleYOffset, bubbleZOffset)
    }

    private func replaceBubbleInstantly(labeled label: String, to anchor: AnchorEntity) {
        currentBubble?.removeFromParent()

        let bubble = CharacterEntityFactory.makeTextBubble(text: label)
        bubble.position = bubbleFinalPosition()
        bubble.components.set(OpacityComponent(opacity: 1))
        let character = characterEntity(for: anchor)
        CharacterEntityFactory.attachBubble(bubble, to: character)
        currentBubble = bubble
    }

    private func startThinkingBubbleAnimation(on anchor: AnchorEntity, afterDelay delay: TimeInterval) {
        stopThinkingBubbleAnimation()

        let generation = personaBuildGeneration
        let phrases = Self.scanThinkingBubbleFlows.randomElement() ?? Self.scanThinkingBubbleFlows[0]
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

            while !Task.isCancelled {
                let shouldContinue = await self.streamBubblePhrase(
                    phrases[index],
                    to: anchor,
                    generation: generation,
                    frameDelay: 0.34,
                    holdDelay: 0.8,
                    isStillWaiting: { self.isUnderstandingObject }
                )
                guard shouldContinue else { return }
                index = (index + 1) % phrases.count
            }
        }
    }

    private func startReplyBubbleAnimation(on anchor: AnchorEntity) {
        stopThinkingBubbleAnimation()

        let generation = personaBuildGeneration
        let phrases = Self.replyThinkingBubbleFlows.randomElement() ?? Self.replyThinkingBubbleFlows[0]
        thinkingBubbleTask = Task { [weak self, weak anchor] in
            var index = 0
            guard let self,
                  let anchor,
                  anchor === self.placedAnchor,
                  generation == self.personaBuildGeneration,
                  self.isReplying
            else { return }

            while !Task.isCancelled {
                let shouldContinue = await self.streamBubblePhrase(
                    phrases[index],
                    to: anchor,
                    generation: generation,
                    frameDelay: 0.32,
                    holdDelay: 0.9,
                    isStillWaiting: { self.isReplying }
                )
                guard shouldContinue else { return }
                index = (index + 1) % phrases.count
            }
        }
    }

    private static let scanThinkingBubbleFlows: [[String]] = [
        [
            "Uuuu What's this ???",
            "Taking a closer look...",
            "Let meee see first...",
            "Interesting...",
            "Tiny camera brain loading..."
        ],
        [
            "Ooo wait, what are you?",
            "Looking at the shape...",
            "Checking the shiny bits...",
            "Reading the object vibes...",
            "Almost got it..."
        ],
        [
            "Hmm, mystery item spotted...",
            "Taking a closer look...",
            "Counting the clues...",
            "Matching the tiny details...",
            "Object brain waking up..."
        ],
        [
            "Hold still, little mystery...",
            "Scanning the colors...",
            "Peeking at the edges...",
            "Thinking with my camera...",
            "Tiny idea loading..."
        ]
    ]

    private static let replyThinkingBubbleFlows: [[String]] = [
        [
            "Wait let me check my tiny brain...",
            "Eh? Not found? WAIT WAIT...",
            "Let me look for clues...",
            "Oh no, still nothing :)",
            "Checking the whole universe...",
            "Okay this is embarrassing..."
        ],
        [
            "Tiny brain booting...",
            "Opening my thought drawers...",
            "Nope, wrong drawer...",
            "Asking my object brain...",
            "Almost got it..."
        ],
        [
            "Thinking cap on...",
            "Looking for clue crumbs...",
            "Hmm, not that one...",
            "Connecting the dots...",
            "Answer smell detected..."
        ],
        [
            "One sec, brain loading...",
            "Shuffling tiny facts...",
            "Checking my memory shelf...",
            "Wiggling the answer loose...",
            "Almost almost..."
        ],
        [
            "Let me thinky-think...",
            "Searching under the idea couch...",
            "Nope, just dust...",
            "Calling my smart sparkle...",
            "Oho, clue found..."
        ]
    ]

    private func showReplyFoundBubble() {
        guard let anchor = placedAnchor else { return }
        replaceBubbleInstantly(labeled: "AHA! Found It!", to: anchor)
    }

    private func streamBubblePhrase(
        _ phrase: String,
        to anchor: AnchorEntity,
        generation: Int,
        frameDelay: TimeInterval,
        holdDelay: TimeInterval,
        isStillWaiting: @escaping () -> Bool
    ) async -> Bool {
        for frame in streamedBubbleFrames(for: phrase) {
            guard !Task.isCancelled,
                  anchor === placedAnchor,
                  generation == personaBuildGeneration,
                  isStillWaiting()
            else { return false }

            replaceBubbleInstantly(labeled: frame, to: anchor)
            try? await Task.sleep(nanoseconds: UInt64(frameDelay * 1_000_000_000))
            guard !Task.isCancelled else { return false }
        }

        try? await Task.sleep(nanoseconds: UInt64(holdDelay * 1_000_000_000))
        return !Task.isCancelled
            && anchor === placedAnchor
            && generation == personaBuildGeneration
            && isStillWaiting()
    }

    private func streamedBubbleFrames(for phrase: String) -> [String] {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let hasEllipsis = trimmed.hasSuffix("...")
        let base = hasEllipsis ? String(trimmed.dropLast(3)) : trimmed
        let words = base.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [trimmed] }

        var frames: [String] = words.indices.map { index in
            words.prefix(index + 1).joined(separator: " ")
        }

        if hasEllipsis, let last = frames.last {
            frames.append(last + ".")
            frames.append(last + "..")
            frames.append(last + "...")
        }

        return frames
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

        CharacterEntityFactory.animateOut(
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

    /// The single AR child under the placement anchor that owns the whole
    /// visible character -- face and bubble are both attached onto this
    /// same entity (via `CharacterEntityFactory.attachFace`/
    /// `attachBubble`) rather than existing as separate top-level
    /// entities under the anchor. It's also the only place that carries a
    /// `BillboardComponent`, so face and bubble always turn to face the
    /// camera together, as one rigid unit.
    private func characterEntity(for anchor: AnchorEntity) -> Entity {
        if let currentCharacter,
           currentCharacter.parent === anchor {
            return currentCharacter
        }

        if let existing = anchor.findEntity(named: CharacterEntityFactory.containerName) {
            currentCharacter = existing
            return existing
        }

        let character = CharacterEntityFactory.makeCharacterContainer()
        anchor.addChild(character)
        currentCharacter = character
        return character
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

        let resolvedPersonality = resolvedPersona.personalityKind.faceKind
        let resolvedExpression = resolvedPersona.emotionStyle.faceExpression
        let resolvedRiskLevel = resolvedPersona.objectIntelligence?.resolvedRiskLevel
            ?? PersonalityMapper.resolvedRiskLevel(suggested: nil, label: resolvedPersona.objectLabel)

        AIDebugLogger.trace("VLM visual persona update", """
        personality=\(resolvedPersona.personalityKind.rawValue)
        riskLevel=\(resolvedRiskLevel.rawValue)
        riskReason=\(resolvedPersona.objectIntelligence?.riskReason ?? "none")
        emotion=\(resolvedPersona.emotionStyle.rawValue)
        faceExpression=\(resolvedExpression.displayName)
        """)

        let transformGeneration = personaBuildGeneration
        _ = await streamBubblePhrase(
            "Got It!",
            to: anchor,
            generation: transformGeneration,
            frameDelay: 0.3,
            holdDelay: 0.45,
            isStillWaiting: { self.isUnderstandingObject }
        )

        guard anchor === placedAnchor,
              transformGeneration == personaBuildGeneration
        else { return }

        replaceBubbleInstantly(labeled: "TRANSFORM!!!", to: anchor)
        try? await Task.sleep(nanoseconds: 750_000_000)

        guard anchor === placedAnchor,
              transformGeneration == personaBuildGeneration
        else { return }

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
        isUnderstandingObject = false
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
        if let anchor = placedAnchor {
            startReplyBubbleAnimation(on: anchor)
        }
        let responseGeneration = personaBuildGeneration
        let priorHistory = history
        history.append(ChatMessage(role: .child, text: message, emotion: nil))
        AIDebugLogger.trace("Chat history before response", """
        priorMessages=\(priorHistory.count)
        totalAfterChild=\(history.count)
        childMessage=\(message)
        """)
        Task {
            let reply = await self.personaGenerator.makeResponse(for: message, persona: persona, history: priorHistory)
            guard responseGeneration == self.personaBuildGeneration,
                  let anchor = self.placedAnchor
            else {
                self.isReplying = false
                return
            }
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
            self.stopThinkingBubbleAnimation()
            self.showReplyFoundBubble()
            AIDebugLogger.trace("Reply found bubble", "AHA! Found It!")

            async let preparedSpeech = self.voice.prepareSpeech(reply.text, emotion: reply.emotion, persona: persona)
            try? await Task.sleep(nanoseconds: 1_350_000_000)
            let speech = await preparedSpeech

            guard responseGeneration == self.personaBuildGeneration,
                  anchor === self.placedAnchor
            else {
                self.isReplying = false
                return
            }

            self.changeExpression(to: reply.emotion.faceExpression)
            self.voice.play(speech)
            let didStreamAnswer = await self.streamBubblePhrase(
                reply.text,
                to: anchor,
                generation: responseGeneration,
                frameDelay: 0.16,
                holdDelay: 0,
                isStillWaiting: { self.isReplying }
            )
            if !didStreamAnswer, responseGeneration == self.personaBuildGeneration {
                self.setBubbleText(reply.text)
            }
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
