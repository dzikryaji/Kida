//
//  CharacterEntityFactory.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 09/07/26.
//


//
//  CharacterEntityFactory.swift
//  Kida
//
//  The single factory for the whole on-object "character": face (eyes,
//  eyebrows, mouth, personality accessory) AND speech bubble. Formerly
//  two separate factories (FaceEntityFactory, BubbleEntityFactory) whose
//  outputs were two independent entities that just happened to be parked
//  under the same anchor -- each with its own `BillboardComponent`, each
//  effectively a standalone billboarded object rendered in the same
//  place. That's why they could visibly drift apart: two entities each
//  independently solving "rotate to face the camera" every frame have no
//  guarantee of picking exactly the same rotation on the same frame.
//
//  Now there's exactly one entity per placed object -- the *character
//  container*, built by `makeCharacterContainer()` -- and it alone owns
//  the `BillboardComponent`. The face and the speech bubble are its two
//  named children (`faceChildName` / `bubbleChildName`), rotated as one
//  rigid unit because there's only one billboard computation happening,
//  at the root. `attachFace`/`attachBubble` are the only way parts get
//  added, and they always parent onto that same container, so "face and
//  bubble live in two different entities under the same anchor" is no
//  longer representable -- there's one entity, with two parts.
//
//  Face and bubble still have independent *lifecycles* on purpose: the
//  face persists across a whole placement while the bubble's text is
//  swapped in and out constantly (thinking dots, greeting, chat replies).
//  `attachFace` replaces only the "face" child; whatever bubble is mid
//  fade-in/out at that moment is left completely alone. That's why the
//  bubble is a sibling of the face inside the container rather than a
//  child *of* the face -- parenting it under the face would mean every
//  personality swap yanks whatever bubble happens to be showing.
//
//  `FaceEntityFactory` and `BubbleEntityFactory` are kept below as
//  typealiases to this type, purely so any other call site in the app
//  that still spells out the old names keeps compiling unchanged.
//

import CoreGraphics
import RealityKit
import UIKit

enum CharacterEntityFactory {

    // MARK: - Character container (the one entity)

    /// Root container name, useful for `AnchorEntity.findEntity(named:)`
    /// lookups after e.g. a scene reload.
    static let containerName = "kida.character"

    /// Name given to the face part when it's attached via `attachFace`.
    static let faceChildName = "face"

    /// Name given to the speech-bubble part when attached via
    /// `attachBubble`.
    static let bubbleChildName = "bubble"

    /// Builds the single entity that a placed object's whole visible
    /// character lives inside -- face and bubble both end up as its
    /// children via `attachFace`/`attachBubble`. Owns the only
    /// `BillboardComponent` in the character: face and bubble parts
    /// themselves are plain (non-billboarded) children, so they turn to
    /// face the camera together, as one rigid unit, rather than each
    /// resolving its own camera-facing rotation independently.
    static func makeCharacterContainer() -> Entity {
        let container = Entity()
        container.name = containerName
        container.components.set(BillboardComponent())
        return container
    }

    /// Attaches `face` to `container` as *the* face child, replacing
    /// (and cleanly stopping the animations of) whatever face was
    /// attached before. Safe to call repeatedly, e.g. once per
    /// personality swap -- each call simply retargets which entity is
    /// "the" face.
    ///
    /// Deliberately does not touch any bubble child: swapping the face
    /// must never interrupt a bubble that's mid fade-in/out.
    static func attachFace(_ face: Entity, to container: Entity) {
        if let existing = container.findEntity(named: faceChildName), existing !== face {
            stopAnimations(for: existing)
            existing.removeFromParent()
        }
        face.name = faceChildName
        container.addChild(face)
    }

    /// Attaches `bubble` to `container` as *the* bubble child. Does not
    /// remove any bubble already present -- callers that need "replace
    /// instantly" semantics remove the old bubble themselves first (see
    /// `ScanViewModel.replaceBubbleInstantly`), since whether the old one
    /// should be torn down immediately or animated out first is a
    /// caller-level policy decision, not something this factory should
    /// assume.
    static func attachBubble(_ bubble: Entity, to container: Entity) {
        bubble.name = bubbleChildName
        container.addChild(bubble)
    }

    /// Convenience accessor for the currently-attached face, if any.
    static func currentFace(in container: Entity) -> Entity? {
        container.findEntity(named: faceChildName)
    }

    /// Convenience accessor for the currently-attached bubble, if any.
    static func currentBubble(in container: Entity) -> Entity? {
        container.findEntity(named: bubbleChildName)
    }

    // ============================================================
    // MARK: - Face
    // ============================================================
    //
    //  Builds the full 3D "face" placed on top of a tapped object: a pair
    //  of eyes, an eyebrow pair, a mouth, plus one signature accessory
    //  that expresses a "personality" for that object (glasses, a bowtie,
    //  a ribbon, or a safety helmet). Owns the pop-in animation for the
    //  whole assembled face, same way EyeEntityFactory owns "how eyes
    //  come to life" -- "how a personality presents itself" is a property
    //  of the face, not something callers should hand-roll.
    //
    //  Also owns "expression" -- sad, happy, or angry. There's only one
    //  mouth mesh and one eyebrow mesh (no separate per-expression
    //  models), so expression is entirely a transform trick: rotate/
    //  nudge/scale the mouth and eyebrows into a different pose. The
    //  mouth in particular is modeled as a frown (that's the unedited
    //  "sad" you're seeing), so "happy" is produced by flipping it
    //  upside down via a negative Y scale rather than swapping in a
    //  different mesh.
    //
    //  Plain-English primer: the parts here are NOT built procedurally
    //  (`generateSphere`, `generateBox`, etc., as in EyeEntityFactory) --
    //  they're pre-modeled `.usdz` files, so this section's job is
    //  loading + positioning + grouping them, not describing their
    //  geometry. `Entity(named:in:)` is RealityKit's async loader for a
    //  `.usdz` asset already sitting in an app target/bundle -- the
    //  RealityKit equivalent of `UIImage(named:)`. NOTE: verify this
    //  throwing async initializer's minimum OS availability against your
    //  deployment target, same caution as the `BillboardComponent` note
    //  in EyeEntityFactory.
    //
    //  Asset inventory (base filename, no extension, expected in the
    //  bundle):
    //    "eye"            -- a single eyeball, mirrored into a pair on demand
    //    "eyes"           -- a pre-built, already-matched eye pair
    //    "eyebrow"        -- a single eyebrow; there is no pre-built pair, so
    //                        this factory always mirrors it into one
    //    "mouth"          -- a single centered mouth (modeled as a frown),
    //                        used as-is for "sad" and transformed for the
    //                        other expressions
    //    "round-glasses"  -- accessory: The Boss
    //    "square-glasses" -- accessory: The Cool
    //    "bowtie"         -- accessory: The Boss (Fancy)
    //    "ribbon"         -- accessory: The Caregiver / Sweet
    //    "safety-hat"     -- accessory: The Cautious
    //
    //  If these assets live in a Reality Composer Pro package rather than
    //  a plain bundle folder, swap `Bundle.main` below for that package's
    //  generated `realityKitContentBundle`.
    //

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
                return [0, -CharacterEntityFactory.mouthVerticalOffset - 0.1, 0]
            case .cautious:
                return [0, CharacterEntityFactory.eyebrowVerticalOffset + 0.08, -0.1]
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

    /// The in-flight/completed base-face build, shared by
    /// `preloadBaseFace()` and `makeFace(personality:)`. Caching the
    /// `Task` itself (rather than a "did it start" bool + an optional
    /// result) is what makes concurrent callers safe: whoever calls in
    /// while a build is already running just awaits the same task
    /// instead of racing it or reading a not-yet-populated result.
    private static var baseFaceTask: Task<Entity, Error>?

    /// Per-face running animation loops, keyed by the face entity's
    /// identity so multiple faces can each independently blink or talk
    /// without stepping on each other, and so switching a given face's
    /// state cancels only that face's previous loop.
    private static var blinkTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    // MARK: Face layout constants

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

    // MARK: Base face

    /// Builds the shared base face (eyes + eyebrows + mouth, no
    /// accessory) if it hasn't been built yet, caching the build as a
    /// `Task` in `baseFaceTask`. Every personality's face is cloned from
    /// this, so the actual asset loading only ever happens once no
    /// matter how many times/which personalities `makeFace` is called
    /// with afterward.
    ///
    /// Safe to call concurrently with itself or with `makeFace` -- a
    /// second caller arriving while a build is already in flight (e.g.
    /// `makeFace` called right after `preloadBaseFace()` kicked off but
    /// before it finished) awaits the *same* `Task` rather than starting
    /// a redundant load or reading `face` before it's populated.
    ///
    /// The returned entity carries no `BillboardComponent` of its own --
    /// it's meant to be attached (via `attachFace`) under a character
    /// container that owns the one, shared billboard for the whole
    /// character.
    @discardableResult
    static func makeBaseFace() async throws -> Entity {
        if let baseFaceTask {
            return try await baseFaceTask.value
        }

        let task = Task<Entity, Error> {
            let baseFace = Entity()

            // Loaded sequentially on purpose -- concurrent Entity(named:)
            // calls for *different* asset names can race in RealityKit's
            // resource loader and come back with mismatched geometry
            // (e.g. the entity named "mouth" ending up with the eyebrow
            // mesh inside it). preloadBaseFace() already runs this ahead
            // of time from the view model's init, so the extra latency
            // from not parallelizing these three loads is invisible in
            // practice.
            let eyes = try await loadAsset(named: "eyes", scale: assetScale)
            let eyebrows = try await makeEyebrowPair()
            let mouth = try await loadAsset(named: "mouth", scale: assetScale)

            eyes.name = "eyes"
            mouth.name = "mouth"

            eyes.position = .zero
            eyebrows.position = [0, eyebrowVerticalOffset, 0]
            mouth.position = [0, -mouthVerticalOffset, 0]

            baseFace.addChild(eyes)
            baseFace.addChild(eyebrows)
            baseFace.addChild(mouth)

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
            _ = try await makeBaseFace()
        } catch {
            print("Failed to preload base face: \(error)")
        }
    }

    // MARK: Public entry point (face)

    /// Loads and assembles a complete face -- eyes, eyebrows, mouth, and
    /// the accessory for `personality` -- centered on its own local
    /// origin, so the caller can freely position it before attaching it
    /// (via `attachFace`) to a character container. Always comes back in
    /// the "sad" (baked/neutral) expression -- call `setExpression`
    /// afterward if you want a different one.
    static func makeFace(personality: Personality) async throws -> Entity {
        // Build the base face (eyes + eyebrows + mouth) once. If
        // `preloadBaseFace()` already ran and finished (e.g. kicked off
        // when the view model started), `makeBaseFace` sees the cached,
        // already-completed task and returns immediately. If the preload
        // is still running, this awaits that *same* task instead of
        // racing it -- so `makeFace` called mid-preload waits for it
        // rather than reading a not-yet-populated face.
        let baseFace = try await makeBaseFace()

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

    // MARK: Expression

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

    // MARK: Face animation

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
    /// `attachFace` already calls this before detaching an old face;
    /// call it directly if you just want everything to go still (e.g.
    /// the whole character is about to be removed from the scene).
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

    // MARK: Shared part-pair building

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

        // Only one actual load call now -- the right side is a clone of
        // the left, not a second concurrent Entity(named:) call for the
        // same asset. Cheaper, and removes another spot where concurrent
        // loads could theoretically race.
        let left = try await loadAsset(named: assetName, scale: scale)
        let right = left.clone(recursive: true)

        left.name = "\(assetName)Left"
        right.name = "\(assetName)Right"

        left.position = [-separation / 2, 0, 0]
        right.position = [separation / 2, 0, 0]
        right.scale.x = -right.scale.x

        group.addChild(left)
        group.addChild(right)

        return group
    }

    private static func makeEyebrowPair() async throws -> Entity {
        try await makeMirroredPair(assetName: "eyebrow", separation: eyeSeparation, scale: assetScale)
    }

    // MARK: Asset loading

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

    // ============================================================
    // MARK: - Speech bubble
    // ============================================================
    //
    //  Builds a 3D "speech bubble" -- a rounded, semi-transparent
    //  gradient-filled background plate plus extruded 3D text plus a
    //  small pointer/tail -- used to show what the classifier thinks the
    //  tapped object is. Also owns the bubble's slide+fade in/out
    //  animations, since "how a bubble appears/disappears" is part of
    //  what makes it a bubble, not something the caller should
    //  reimplement.
    //
    //  Visual language matches the 2D `SpeechBubble` SwiftUI view's
    //  "system" style -- same gold gradient, same dark text -- just
    //  expressed in RealityKit terms instead of SwiftUI ones. The
    //  background plate is a true pill/stadium shape (fully rounded
    //  ends) and renders semi-transparent so it doesn't fully occlude
    //  whatever real-world object it's pointing at.
    //
    //  Plain-English primer: `MeshResource.generateText(...)` turns a
    //  Swift string into an actual 3D mesh (letters with real depth, not
    //  a flat picture of text), the same way `generateSphere`/
    //  `generateBox` turn numbers into 3D shapes. `UnlitMaterial` is used
    //  instead of the eyes' `SimpleMaterial` because unlit materials
    //  render at a flat, constant brightness regardless of scene
    //  lighting -- important for text, which needs to stay legible even
    //  in a dim room. RealityKit materials don't support gradients out
    //  of the box, so the gradient fill below is done by rendering a
    //  tiny top-to-bottom gradient image with Core Graphics and using
    //  that as the material's texture. Transparency on an `UnlitMaterial`
    //  also requires explicitly opting into `.transparent` blending --
    //  alpha in the color/texture is otherwise ignored.
    //
    //  Background shape note: the plate uses `generatePlane(width:height:
    //  cornerRadius:)`, not `generateBox`. A box's corner radius gets
    //  clamped relative to its *smallest* dimension across all three
    //  axes -- with a paper-thin depth like this plate's, that clamp
    //  effectively zeroes out any rounding no matter how large a value
    //  is requested. A plane has no depth axis to clamp against, so the
    //  requested radius is honored in full, which is what actually
    //  produces a pill shape.
    //

    // MARK: Bubble palette (kept in step with ChatStyle in the 2D chat UI)

    static let fillTop: UIColor    = UIColor(red: 0.953, green: 0.788, blue: 0.412, alpha: 1) // #F3C969
    static let fillBottom: UIColor = UIColor(red: 0.878, green: 0.659, blue: 0.243, alpha: 1) // #E0A83E
    static let textColor: UIColor  = UIColor(red: 0.290, green: 0.231, blue: 0.122, alpha: 1) // #4A3B1F

    static let fontSize: Float = 0.014
    static let extrusionDepth: Float = 0.002
    static let horizontalPadding: Float = 0.04   // extra roomy so short text still reads as a pill, not a circle
    static let verticalPadding: Float = 0.03

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

    /// Builds the full bubble reading `message`, centered on its own
    /// local origin so the caller can freely position it before
    /// attaching it (via `attachBubble`) to a character container. Long
    /// text wraps onto additional lines (growing the bubble downward)
    /// instead of stretching the bubble wider than `maxTextWidth`.
    ///
    /// Carries no `BillboardComponent` of its own -- like the face, it
    /// relies on the character container's single shared billboard.
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

        return group
    }

    // MARK: Gradient fill

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

    // MARK: Bubble animation

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

// MARK: - Back-compat aliases
//
// Any other call site in the app that still spells out the old,
// pre-merge factory names keeps compiling unchanged -- both names now
// just point at the one merged type above.
typealias FaceEntityFactory = CharacterEntityFactory
typealias BubbleEntityFactory = CharacterEntityFactory
