//
//  FaceEntityFactory.swift
//  Kida
//
//  Builds the full 3D "face" placed on top of a tapped object: a pair of
//  eyes, an eyebrow pair, a mouth, plus one signature accessory that
//  expresses a "personality" for that object (glasses, a bowtie, a
//  ribbon, or a safety helmet). Owns the pop-in animation for the whole
//  assembled face, same way EyeEntityFactory owns "how eyes come to
//  life" -- "how a personality presents itself" is a property of the
//  face, not something callers should hand-roll.
//
//  Also owns "expression" -- sad, happy, or angry. There's only one
//  mouth mesh and one eyebrow mesh (no separate per-expression models),
//  so expression is entirely a transform trick: rotate/nudge/scale the
//  mouth and eyebrows into a different pose. The mouth in particular is
//  modeled as a frown (that's the unedited "sad" you're seeing), so
//  "happy" is produced by flipping it upside down via a negative Y
//  scale rather than swapping in a different mesh.
//
//  Plain-English primer: the parts here are NOT built procedurally
//  (`generateSphere`, `generateBox`, etc., as in EyeEntityFactory) --
//  they're pre-modeled `.usdz` files, so this factory's job is loading +
//  positioning + grouping them, not describing their geometry.
//  `Entity(named:in:)` is RealityKit's async loader for a `.usdz` asset
//  already sitting in an app target/bundle -- the RealityKit equivalent
//  of `UIImage(named:)`. NOTE: verify this throwing async initializer's
//  minimum OS availability against your deployment target, same caution
//  as the `BillboardComponent` note in EyeEntityFactory.
//
//  Asset inventory (base filename, no extension, expected in the bundle):
//    "eye"            -- a single eyeball, mirrored into a pair on demand
//    "eyes"           -- a pre-built, already-matched eye pair
//    "eyebrow"        -- a single eyebrow asset from AR/Model/eyebrow.usdz;
//                        mirrored into a pair here
//    "mouth"          -- a single centered mouth (modeled as a frown),
//                        used as-is for "sad" and transformed for the
//                        other expressions
//    "round-glasses"  -- accessory: The Boss
//    "square-glasses" -- accessory: The Cool
//    "bowtie"         -- accessory: The Boss (Fancy)
//    "ribbon"         -- accessory: The Caregiver / Sweet
//    "safety-hat"     -- accessory: The Cautious
//
//  If these assets live in a Reality Composer Pro package rather than a
//  plain bundle folder, swap `Bundle.main` below for that package's
//  generated `realityKitContentBundle`.
//

import RealityKit
import UIKit

enum FaceEntityFactory {

    /// The five expressive "personalities" a face can be assembled as.
    /// Each one is defined entirely by which accessory it wears -- eyes,
    /// eyebrows, and mouth are shared across all personalities.
    enum Personality: CaseIterable, Hashable {
        case boss       // The Boss            -- round glasses
        case cool       // The Cool            -- square glasses
        case fancy      // The Boss / Fancy    -- bowtie
        case caregiver  // The Caregiver/Sweet -- ribbon
        case cautious   // The Cautious        -- safety helmet

        /// Base filename (no extension) of the .usdz accessory that
        /// expresses this personality.
        var accessoryAssetName: String {
            switch self {
            case .boss: return "round-glasses"
            case .cool: return "square-glasses"
            case .fancy: return "bowtie"
            case .caregiver: return "ribbon"
            case .cautious: return "safety-hat"
            }
        }

        /// Corrective scale applied to *this* accessory only.
        ///
        /// Unlike the face parts (eyes/eyebrows/mouth), which all share
        /// one `assetScale` because they were modeled together at a
        /// consistent size, each accessory is a separate asset that may
        /// have been exported at its own arbitrary scale. Tune each case
        /// independently against its actual `.usdz` until it reads at
        /// the right size sitting on the face.
        var accessoryScale: Float {
            switch self {
            case .boss: return 0.1
            case .cool: return 0.1
            case .fancy: return 0.05
            case .caregiver: return 0.05
            case .cautious: return 0.15
            }
        }

        /// Where the accessory sits relative to the face group's local
        /// origin (which itself sits at the eyes' center). Glasses sit
        /// right over the eyes; the bowtie/ribbon sit below the mouth at
        /// a "collar" height; the helmet sits above the eyebrows, on top
        /// of the head.
        var accessoryOffset: SIMD3<Float> {
            switch self {
            case .boss, .cool:
                return [0, 0, 0.1]
            case .fancy, .caregiver:
                return [0, -FaceEntityFactory.mouthVerticalOffset - 0.1, 0]
            case .cautious:
                return [0, FaceEntityFactory.eyebrowVerticalOffset + 0.08, -0.1]
            }
        }

        /// Human-readable label, useful for debug UI / accessibility.
        var displayName: String {
            switch self {
            case .boss: return "The Boss"
            case .cool: return "The Cool"
            case .fancy: return "The Boss (Fancy)"
            case .caregiver: return "The Caregiver"
            case .cautious: return "The Cautious"
            }
        }
    }

    /// The three expressions a face can be posed in. `.sad` is the
    /// baked/neutral pose -- exactly how the mouth and eyebrow meshes
    /// were modeled, no transform changes applied.
    enum Expression: CaseIterable, Hashable {
        case sad
        case happy
        case angry

        var displayName: String {
            switch self {
            case .sad: return "Sad"
            case .happy: return "Happy"
            case .angry: return "Angry"
            }
        }

        var debugName: String {
            switch self {
            case .sad: return "sad"
            case .happy: return "happy"
            case .angry: return "angry"
            }
        }

        var pose: Pose {
            switch self {
            case .sad:
                return Pose()

            case .happy:
                return Pose(
                    mouthScaleY: -1,
                    mouthVerticalNudge: -0.06,
                    eyebrowRotation: -(.pi / 10),
                    eyebrowVerticalNudge: 0.002
                )

            case .angry:
                return Pose(
                    mouthScaleX: 0.85,
                    mouthVerticalNudge: -0.001,
                    eyebrowRotation: .pi / 6,
                    eyebrowVerticalNudge: -0.02,
                    eyeSeparation: -0.05
                )
            }
        }

        struct Pose {
            var mouthRotation: Float = 0
            var mouthScaleX: Float = 1
            var mouthScaleY: Float = 1
            var mouthVerticalNudge: Float = 0

            var eyebrowRotation: Float = 0
            var eyebrowVerticalNudge: Float = 0
            var eyeSeparation: Float = 0
        }
    }

    private static var faces: [Personality: Entity] = [:]
    private static var baseFaceTask: Task<Entity, Error>?

    /// Per-face running animation loops, keyed by the face entity's
    /// identity so multiple faces can each independently blink or talk
    /// without stepping on each other, and so switching a given face's
    /// state cancels only that face's previous loop.
    private static var blinkTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    // MARK: - Layout constants

    /// Horizontal distance between the two eyes' (or eyebrows') centers,
    /// matching the separation baked into EyeEntityFactory so a face
    /// built here lines up with procedural eyes at the same scale.
    static let eyeSeparation: Float = 0
    static let eyebrowVerticalOffset: Float = 0.016
    static let mouthVerticalOffset: Float = 0.02

    /// Corrective scale applied to the shared face parts only -- eyes,
    /// eyebrows, and mouth.
    ///
    /// Unlike EyeEntityFactory's procedural spheres -- which are
    /// generated directly at their final real-world size (a
    /// `scleraRadius` of 0.009m, an `eyeSeparation` of 0.028m, a few
    /// centimeters total) -- these assets carry whatever scale they were
    /// modeled/exported at, which has no reason to already match that.
    /// This constant brings them down into the same few-centimeters
    /// range so a face sits on an object the way the procedural eyes
    /// used to. Tune this against your actual assets: shrink it further
    /// if the face still reads as oversized, or the reverse if it's too
    /// small.
    ///
    /// Accessories do NOT use this constant -- each one is scaled by its
    /// own `Personality.accessoryScale` instead, since they're separate
    /// assets with no reason to share a common export scale.
    static let assetScale: Float = 0.1

    // MARK: - Base face

    /// Builds the shared base face (eyes + eyebrows + mouth, no
    /// accessory) if it hasn't been built yet, caching the build as a
    /// `Task` in `baseFaceTask`.
    /// Every personality's face is cloned from this, so the actual asset
    /// loading only ever happens once no matter how many times/which
    /// personalities `makeFace` is called with afterward.
    ///
    /// Safe to call concurrently with itself or with `makeFace` -- a
    /// second caller arriving while a build is already in flight awaits
    /// the same `Task` rather than starting a redundant load.
    @discardableResult
    private static func buildBaseFaceIfNeeded() async throws -> Entity {
        if let baseFaceTask {
            return try await baseFaceTask.value
        }

        let task = Task<Entity, Error> {
            let baseFace = Entity()

            async let eyesTask = loadAsset(named: "eyes", scale: assetScale)
            async let eyebrowsTask = makeEyebrowPair()
            async let mouthTask = loadAsset(named: "mouth", scale: assetScale)

            let eyes = try await eyesTask
            let eyebrows = try await eyebrowsTask
            let mouth = try await mouthTask
            eyes.name = "eyes"
            eyebrows.name = "eyebrows"
            mouth.name = "mouth"

            eyes.position = .zero
            eyebrows.position = [0, eyebrowVerticalOffset, 0]
            mouth.position = [0, -mouthVerticalOffset, 0]

            baseFace.addChild(eyes)
            baseFace.addChild(eyebrows)
            baseFace.addChild(mouth)
            baseFace.components.set(BillboardComponent())

            return baseFace
        }

        baseFaceTask = task

        do {
            return try await task.value
        } catch {
            baseFaceTask = nil
            throw error
        }
    }

    /// Warms the shared base-face cache (eyes + eyebrows + mouth) ahead
    /// of time, so the *first* real `makeFace(personality:)` call --
    /// typically triggered by the user's first tap-to-place -- doesn't
    /// have to pay for loading those three assets itself, only for the
    /// personality's own accessory.
    ///
    /// Intended to be fired once, as soon as possible -- e.g. from the
    /// owning view model's `init` -- so the load has time to finish in
    /// the background while the user is still finding a surface to tap.
    /// Swallows its own errors (logging instead) since a failed preload
    /// isn't fatal: `makeFace` will simply retry the same load itself
    /// the first time it's actually needed.
    static func preloadBaseFace() async {
        do {
            _ = try await buildBaseFaceIfNeeded()
        } catch {
            print("Failed to preload base face: \(error)")
        }
    }

    // MARK: - Public entry point

    /// Returns only the shared face parts -- eyes, eyebrows, and mouth --
    /// with no personality accessory. This is used for the instant scan
    /// placement while the VLM is still deciding which prop belongs on
    /// the object.
    static func makeBaseFace() async throws -> Entity {
        let baseFace = try await buildBaseFaceIfNeeded()
        return baseFace.clone(recursive: true)
    }

    /// Loads and assembles a complete face -- eyes, eyebrows, mouth, and
    /// the accessory for `personality` -- centered on its own local
    /// origin, so the caller can freely position/anchor it, same as
    /// `BubbleEntityFactory.makeTextBubble` and
    /// `EyeEntityFactory.makeEyePair`. Always comes back in the "sad"
    /// (baked/neutral) expression -- call `setExpression` afterward if
    /// you want a different one.
    static func makeFace(personality: Personality) async throws -> Entity {
        // Build the base face (eyes + eyebrows + mouth) once. If
        // `preloadBaseFace()` already ran (e.g. kicked off when the view
        // model started), this is a cache hit and returns immediately.
        let baseFace = try await buildBaseFaceIfNeeded()

        // Build this personality once.
        if faces[personality] == nil {
            let personalityFace = baseFace.clone(recursive: true)

            let accessory = try await loadAsset(
                named: personality.accessoryAssetName,
                scale: personality.accessoryScale
            )
            accessory.position = personality.accessoryOffset
            personalityFace.addChild(accessory)

            faces[personality] = personalityFace
        }

        // Return a clone so callers can modify it independently.
        return faces[personality]!.clone(recursive: true)
    }

    /// Builds a mirrored pair from the single "eye" asset instead of the
    /// pre-built "eyes" pair used by `makeFace`. Useful if a caller wants
    /// independent control over each eye -- e.g. a wink, or blink states
    /// applied to just one side -- rather than the matched pair.
    static func makeEyePair() async throws -> Entity {
        try await makeMirroredPair(assetName: "eye", separation: eyeSeparation, scale: assetScale)
    }

    // MARK: - Expression

    /// Poses `face` -- a live entity previously returned by `makeFace`
    /// (or a clone of one) -- into `expression`, animating the mouth and
    /// eyebrows into place over `duration`.
    ///
    /// Each part's target transform is always recomputed from scratch
    /// from the layout constants above rather than nudged relative to
    /// wherever it currently sits, so switching sad -> happy -> angry ->
    /// sad repeatedly lands on the exact same pose every time instead of
    /// drifting or compounding rotations.
    ///
    /// Safe to call on a face that hasn't finished its `popIn` yet, and
    /// safe to call repeatedly/rapidly -- each call simply re-targets the
    /// same three parts' animations.
    static func setExpression(
        _ expression: Expression,
        on face: Entity,
        duration: TimeInterval,
        timingFunction: AnimationTimingFunction = .easeInOut
    ) {
        let pose = expression.pose

        if let mouth = face.findEntity(named: "mouth") {
            var target = mouth.transform
            target.translation = [0, -mouthVerticalOffset + pose.mouthVerticalNudge, 0]
            target.rotation = simd_quatf(angle: pose.mouthRotation, axis: [0, 0, 1])
            target.scale = [
                assetScale * pose.mouthScaleX,
                assetScale * pose.mouthScaleY,
                assetScale
            ]

            mouth.move(
                to: target,
                relativeTo: mouth.parent,
                duration: duration,
                timingFunction: timingFunction
            )
        }

        if let leftBrow = face.findEntity(named: "eyebrowLeft") {
            var target = leftBrow.transform
            target.translation = [-pose.eyeSeparation / 2, eyebrowVerticalOffset + pose.eyebrowVerticalNudge, 0]
            target.rotation = simd_quatf(angle: pose.eyebrowRotation, axis: [0, 0, 1])
            target.scale = SIMD3<Float>(repeating: assetScale)

            leftBrow.move(
                to: target,
                relativeTo: leftBrow.parent,
                duration: duration,
                timingFunction: timingFunction
            )
        }

        if let rightBrow = face.findEntity(named: "eyebrowRight") {
            var target = rightBrow.transform
            target.translation = [pose.eyeSeparation / 2, eyebrowVerticalOffset + pose.eyebrowVerticalNudge, 0]
            target.rotation = simd_quatf(angle: -pose.eyebrowRotation, axis: [0, 0, 1])
            target.scale = [-assetScale, assetScale, assetScale]

            rightBrow.move(
                to: target,
                relativeTo: rightBrow.parent,
                duration: duration,
                timingFunction: timingFunction
            )
        }
    }

    // MARK: - Animation

    /// Animates a freshly-assembled (scaled-to-zero) face growing up to
    /// full size, mirroring `EyeEntityFactory.popIn`. Callers are expected
    /// to have already set the entity's initial scale (e.g. near-zero)
    /// before calling this.
    static func popIn(_ face: Entity, duration: TimeInterval, timingFunction: AnimationTimingFunction = .easeOut) {
        var target = face.transform
        target.scale = SIMD3<Float>(repeating: 1)
        face.move(to: target, relativeTo: face.parent, duration: duration, timingFunction: timingFunction)
    }


    /// Cancels any running idle/talking loop on `face` without starting
    /// a new one, leaving the mouth/eyes wherever they currently are.
    /// `setState` already calls this before starting its own loop; call
    /// it directly if you just want everything to go still (e.g. the
    /// face is about to be removed from the scene).
    static func stopAnimations(for face: Entity) {
        let id = ObjectIdentifier(face)

        blinkTasks[id]?.cancel()
        blinkTasks[id] = nil
    }

    /// Loops forever: wait a random few-second beat, blink once, repeat.
    /// The random gap (rather than a fixed interval) is what keeps it
    /// reading as a living face instead of a metronome.
    static func startBlinking(on face: Entity) {
        guard face.findEntity(named: "eyes") != nil else { return }

        let task = Task { [weak face] in
            while !Task.isCancelled {
                let gap = Double.random(in: 2.0...5.5)
                try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                guard let face, !Task.isCancelled else { return }
                await blinkOnce(face)
            }
        }

        blinkTasks[ObjectIdentifier(face)] = task
    }

    /// A single blink: squash the eyes' Y scale down to nearly flat then
    /// back up to full, close-then-open, awaiting each leg so the loop
    /// above doesn't queue the next blink's wait on top of this one.
    private static func blinkOnce(_ face: Entity) async {
        guard let eyes = face.findEntity(named: "eyes") else { return }

        let closeDuration = 0.07
        let openDuration = 0.09

        var closed = eyes.transform
        closed.scale.y = assetScale * 0.05
        eyes.move(to: closed, relativeTo: eyes.parent, duration: closeDuration, timingFunction: .easeIn)
        try? await Task.sleep(nanoseconds: UInt64(closeDuration * 1_000_000_000))

        guard !Task.isCancelled else { return }

        var open = eyes.transform
        open.scale.y = assetScale
        eyes.move(to: open, relativeTo: eyes.parent, duration: openDuration, timingFunction: .easeOut)
        try? await Task.sleep(nanoseconds: UInt64(openDuration * 1_000_000_000))
    }

    // MARK: - Shared part-pair building

    /// Builds a symmetric left/right pair by loading the same named asset
    /// twice and mirroring the right copy across x. Used for eyebrows
    /// (no pre-built pair asset exists) and available for eyes too, via
    /// `makeEyePair`. Names the two children "\(assetName)Left" /
    /// "\(assetName)Right" (e.g. "eyebrowLeft"/"eyebrowRight") so callers
    /// like `setExpression` can find them again after cloning.
    private static func makeMirroredPair(
        assetName: String,
        separation: Float,
        scale: Float
    ) async throws -> Entity {
        let group = Entity()

        async let leftTask = loadAsset(named: assetName, scale: scale)
        async let rightTask = loadAsset(named: assetName, scale: scale)

        let left = try await leftTask
        let right = try await rightTask

        left.name = "\(assetName)Left"
        right.name = "\(assetName)Right"

        left.position = [-separation / 2, 0, 0]
        right.position = [separation / 2, 0, 0]
        // Mirror the right side across x so a shape modeled with a
        // natural left/right arch (an eyebrow's arch, an eye's iris
        // highlight) reads correctly on both sides instead of placing
        // two identical, same-handed copies. Negate (not hard-set to -1)
        // so this composes correctly with the scale magnitude `loadAsset`
        // already applied on every axis.
        right.scale.x = -right.scale.x

        group.addChild(left)
        group.addChild(right)

        return group
    }

    private static func makeEyebrowPair() async throws -> Entity {
        let group = try await makeMirroredPair(assetName: "eyebrow", separation: eyeSeparation, scale: assetScale)
        applyEyebrowMaterial(to: group)
        return group
    }

    private static func applyEyebrowMaterial(to entity: Entity) {
        let material = SimpleMaterial(
            color: UIColor(red: 0.015, green: 0.013, blue: 0.012, alpha: 1),
            isMetallic: false
        )
        applyMaterial(material, to: entity)
    }

    private static func applyMaterial(_ material: SimpleMaterial, to entity: Entity) {
        if let modelEntity = entity as? ModelEntity {
            modelEntity.model?.materials = [material]
        }

        for child in entity.children {
            applyMaterial(material, to: child)
        }
    }

    // MARK: - Asset loading

    /// Loads a single named `.usdz` asset from the app bundle. Each
    /// exported file's `defaultPrim` is `"Root"`, so the returned entity
    /// is that root Xform -- safe to reposition/reparent directly.
    ///
    /// `scale` is required rather than defaulted so every call site has
    /// to be explicit about which corrective scale applies: face parts
    /// pass the shared `assetScale`, accessories pass their own
    /// `Personality.accessoryScale`.
    private static func loadAsset(named name: String, scale: Float, in bundle: Bundle = .main) async throws -> Entity {
        let entity = try await Entity(named: name, in: bundle)
        entity.scale = SIMD3<Float>(repeating: scale)
        return entity
    }
}
