//
//  ARPlacementService.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 06/07/26.
//


//
//  ARPlacementService.swift
//  DummyKida
//
//  Owns the "where in the real world does this go" logic: turning a 2D tap
//  point into a 3D world transform (via raycast, falling back to a fixed
//  distance in front of the camera if no plane is found), and creating the
//  AnchorEntity that transform anchors to.
//
//  Pulled out of ScanViewModel so that (a) the view model isn't doing
//  ARKit/RealityKit math directly, and (b) placement logic can be unit
//  tested or swapped out (e.g. a mock in tests) via the protocol below.
//

import ARKit
import RealityKit

protocol ARPlacementServicing {
    /// Resolves a 2D screen tap into a 3D world transform, preferring a real
    /// or estimated vertical plane hit, and falling back to a point a fixed
    /// distance in front of the camera if neither raycast succeeds.
    func resolvePlacementTransform(for point: CGPoint, in arView: ARView) -> simd_float4x4?

    /// Creates an AnchorEntity at the given world transform and adds it to
    /// the scene.
    func placeAnchor(at transform: simd_float4x4, in arView: ARView) -> AnchorEntity
}

final class ARPlacementService: ARPlacementServicing {

    private let fallbackDistance: Float = 0.3 // Meters in front of camera

    func resolvePlacementTransform(for point: CGPoint, in arView: ARView) -> simd_float4x4? {
        if let result = arView.raycast(
            from: point,
            allowing: .existingPlaneGeometry,
            alignment: .vertical
        ).first {
            return result.worldTransform
        }

        if let result = arView.raycast(
            from: point,
            allowing: .estimatedPlane,
            alignment: .vertical
        ).first {
            return result.worldTransform
        }

        guard let ray = arView.ray(through: point) else { return nil }

        let worldPosition = ray.origin + ray.direction * fallbackDistance

        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(
            worldPosition.x,
            worldPosition.y,
            worldPosition.z,
            1
        )

        return transform
    }

    func placeAnchor(at transform: simd_float4x4, in arView: ARView) -> AnchorEntity {
        let anchor = AnchorEntity(world: transform)
        arView.scene.addAnchor(anchor)
        return anchor
    }
}
