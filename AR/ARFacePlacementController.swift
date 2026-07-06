import ARKit
import RealityKit
import UIKit

@MainActor
final class ARFacePlacementController {
    private weak var arView: ARView?
    private var faceAnchor: AnchorEntity?
    private var faceEntity: ObjectFaceEntity?
    private var lastTargetPoint: CGPoint?

    init(arView: ARView) {
        self.arView = arView
    }

    func startSession() {
        guard let arView else {
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        arView.automaticallyConfigureSession = false
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pauseSession() {
        arView?.session.pause()
    }

    func updateTargetPoint(_ point: CGPoint) {
        lastTargetPoint = point
    }

    func currentPixelBuffer() -> CVPixelBuffer? {
        arView?.session.currentFrame?.capturedImage
    }

    func currentTargetPointNormalized() -> CGPoint? {
        guard let arView, let lastTargetPoint else {
            return nil
        }

        let bounds = arView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        return CGPoint(
            x: min(max(lastTargetPoint.x / bounds.width, 0), 1),
            y: min(max(1 - (lastTargetPoint.y / bounds.height), 0), 1)
        )
    }

    func placeFace(
        near boundingBox: CGRect? = nil,
        objectPoint: CGPoint? = nil,
        initialEmotion: Emotion,
        visualStyle: FaceVisualStyle = .standard
    ) -> Bool {
        guard let arView else {
            return false
        }

        let targetPoint = objectPoint
            .map { screenPoint(forNormalizedPoint: $0, in: arView.bounds) }
            ?? boundingBox
            .map { screenPoint(for: $0, in: arView.bounds) }
            ?? lastTargetPoint
            ?? CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        let detectedPlanePosition = raycastPosition(from: targetPoint, in: arView)
        guard var position = detectedPlanePosition
            ?? cameraForwardPosition(in: arView, distance: 0.55) else {
            return false
        }

        removeCurrentFace()

        if let raycastPosition = detectedPlanePosition {
            let directionToCamera = currentCameraPosition(in: arView) - raycastPosition
            position = raycastPosition + (normalized(directionToCamera, fallback: [0, 0, 1]) * 0.08)
            position.y += 0.045
        }

        let anchor = AnchorEntity(world: position)
        let face = ObjectFaceEntity(style: visualStyle)
        face.scale = [0.95, 0.95, 0.95]
        face.apply(emotion: initialEmotion, animated: false)
        anchor.addChild(face)
        arView.scene.addAnchor(anchor)

        let cameraPosition = currentCameraPosition(in: arView)
        let faceWorldPosition = face.position(relativeTo: nil)
        face.look(at: cameraPosition, from: faceWorldPosition, relativeTo: nil)

        faceAnchor = anchor
        faceEntity = face
        return true
    }

    func applyEmotion(_ emotion: Emotion, animated: Bool) {
        if animated {
            faceEntity?.blinkThenApply(emotion: emotion)
        } else {
            faceEntity?.apply(emotion: emotion, animated: false)
        }
    }

    func startTalking(emotion: Emotion) {
        faceEntity?.startTalking(emotion: emotion)
    }

    func speakWord(_ word: String, emotion: Emotion) {
        faceEntity?.speakWord(word, emotion: emotion)
    }

    func stopTalking(restingEmotion: Emotion) {
        faceEntity?.stopTalking(restingEmotion: restingEmotion)
    }

    private func removeCurrentFace() {
        if let faceAnchor {
            arView?.scene.removeAnchor(faceAnchor)
        }
        faceAnchor = nil
        faceEntity = nil
    }

    private func screenPoint(for normalizedBoundingBox: CGRect, in bounds: CGRect) -> CGPoint {
        let centerX = normalizedBoundingBox.midX
        let centerY = 1 - normalizedBoundingBox.midY
        return CGPoint(
            x: bounds.width * min(max(centerX, 0), 1),
            y: bounds.height * min(max(centerY, 0), 1)
        )
    }

    private func screenPoint(forNormalizedPoint point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: bounds.width * min(max(point.x, 0), 1),
            y: bounds.height * min(max(1 - point.y, 0), 1)
        )
    }

    private func raycastPosition(from point: CGPoint, in arView: ARView) -> SIMD3<Float>? {
        guard let query = arView.makeRaycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
              let result = arView.session.raycast(query).first else {
            return nil
        }

        let transform = result.worldTransform
        return SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
    }

    private func cameraForwardPosition(in arView: ARView, distance: Float) -> SIMD3<Float>? {
        guard let transform = arView.session.currentFrame?.camera.transform else {
            return nil
        }

        let cameraPosition = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let cameraForward = -SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        )

        return cameraPosition + (normalized(cameraForward, fallback: [0, 0, -1]) * distance)
    }

    private func currentCameraPosition(in arView: ARView) -> SIMD3<Float> {
        guard let transform = arView.session.currentFrame?.camera.transform else {
            return arView.cameraTransform.translation
        }

        return SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
    }

    private func normalized(_ vector: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length > 0.0001 else {
            return fallback
        }

        return vector / length
    }
}
