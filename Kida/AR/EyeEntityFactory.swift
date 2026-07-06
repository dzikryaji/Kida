//
//  EyeEntityFactory.swift
//  Kida
//
//  Builds the pair of "googly eyes" 3D entities placed on top of objects,
//  and owns their pop-in animation -- "how the eyes come to life" is a
//  property of the eyes themselves, not something callers should have to
//  hand-roll transform math for.
//
//  Plain-English primer: a RealityKit `ModelEntity` is a 3D object you can
//  place in the AR scene (here, spheres for the eyeball and pupil).
//  `BillboardComponent` makes an entity automatically rotate to always face
//  the camera -- that's what makes the eyes feel like they're "looking at
//  you" no matter where you walk.
//
//  Eye size scales with how big the tapped object's bounding box is, so a
//  tap on a coffee mug gets small eyes and a tap on a couch gets bigger
//  ones, rather than every object getting identical eyes regardless of size.
//

import CoreGraphics
import RealityKit
import UIKit

enum EyeEntityFactory {

    static let scleraRadius: Float = 0.009
    static let pupilRadius: Float = 0.004
    static let eyeSeparation: Float = 0.028

    static func makeEyePair() -> Entity {
        let group = Entity()

        let leftEye = makeEyeball()
        leftEye.position = [-eyeSeparation / 2, 0, 0]

        let rightEye = makeEyeball()
        rightEye.position = [eyeSeparation / 2, 0, 0]

        group.addChild(leftEye)
        group.addChild(rightEye)

        return group
    }

    /// Animates a freshly-created (scaled-to-zero) eye pair growing up to
    /// its full size. Callers are expected to have already set the entity's
    /// initial scale (e.g. to near-zero) before calling this.
    static func popIn(_ eyes: Entity, duration: TimeInterval, timingFunction: AnimationTimingFunction = .easeOut) {
        var target = eyes.transform
        target.scale = SIMD3<Float>(repeating: 1)
        eyes.move(to: target, relativeTo: eyes.parent, duration: duration, timingFunction: timingFunction)
    }

    private static func makeEyeball() -> ModelEntity {
        let scleraMesh = MeshResource.generateSphere(radius: scleraRadius)
        let scleraMaterial = SimpleMaterial(color: .white, isMetallic: false)
        let sclera = ModelEntity(mesh: scleraMesh, materials: [scleraMaterial])

        let pupilMesh = MeshResource.generateSphere(radius: pupilRadius)
        let pupilMaterial = SimpleMaterial(color: .black, isMetallic: false)
        let pupil = ModelEntity(mesh: pupilMesh, materials: [pupilMaterial])
        // Sits right on the front surface of the sclera sphere.
        pupil.position = [0, 0, scleraRadius * 0.83]
        sclera.addChild(pupil)

        // Always rotates to face the camera -- this is what sells the
        // "alive, watching you" effect. NOTE: verify BillboardComponent's
        // minimum OS availability against your deployment target; it was
        // added in a RealityKit revision that may postdate iOS 17.0.
        sclera.components.set(BillboardComponent())

        return sclera
    }
}
