import CoreGraphics
import CoreVideo
import Foundation
import UIKit

/// Teaching sample for using Kida's SAM segmenter.
///
/// This file is not part of the app target by default. It shows the minimum flow:
/// camera frame + tap point -> SAM mask -> centroid/bounding box -> screen anchor.
///
/// Required model files in the app bundle:
/// - SAM2_1SmallImageEncoderFLOAT16.mlpackage
/// - SAM2_1SmallPromptEncoderFLOAT16.mlpackage
/// - SAM2_1SmallMaskDecoderFLOAT16.mlpackage
final class SAMUsageExample {
    private let segmenter: ObjectSegmenting

    init(segmenter: ObjectSegmenting = SAM2ObjectSegmenter()) {
        self.segmenter = segmenter
    }

    /// Call this once before the first scan, for example when the camera screen opens.
    func warmUpSAM() async {
        await segmenter.prepare()
    }

    /// Segment the object the user tapped.
    ///
    /// - Parameters:
    ///   - pixelBuffer: Camera image. In Kida this usually comes from `ARFrame.capturedImage`.
    ///   - tapInView: The place the child tapped in screen/view coordinates.
    ///   - viewSize: The size of the AR/camera view that received the tap.
    ///   - includePreview: Use `true` for debugging UI, `false` for fastest production scans.
    func segmentTappedObject(
        pixelBuffer: CVPixelBuffer,
        tapInView: CGPoint,
        viewSize: CGSize,
        includePreview: Bool = true
    ) async -> SAMExampleResult? {
        let normalizedTap = SAMAnchorMath.normalizedTargetPoint(
            tapInView: tapInView,
            viewSize: viewSize
        )

        guard let segmentation = await segmenter.segment(
            pixelBuffer: PixelBufferReference(value: pixelBuffer),
            targetPoint: normalizedTap,
            includePreview: includePreview
        ) else {
            return nil
        }

        return SAMExampleResult(
            boundingBox: segmentation.boundingBox,
            centroid: segmentation.centroid,
            screenAnchorPoint: SAMAnchorMath.screenPoint(
                fromNormalizedPoint: segmentation.centroid,
                viewSize: viewSize
            ),
            screenBoundingBox: SAMAnchorMath.screenRect(
                fromNormalizedBoundingBox: segmentation.boundingBox,
                viewSize: viewSize
            ),
            areaFraction: segmentation.areaFraction,
            maskPreviewImage: segmentation.maskPreviewImage
        )
    }
}

struct SAMExampleResult {
    /// Normalized CGRect from SAM, values are 0...1.
    /// Kida stores this using Vision-style coordinates: origin is bottom-left.
    let boundingBox: CGRect

    /// Normalized CGPoint from SAM, values are 0...1.
    /// `centroid.x` and `centroid.y` are already CGFloat.
    let centroid: CGPoint

    /// Use this 2D point for UI overlays, or pass it into an AR raycast.
    let screenAnchorPoint: CGPoint

    /// Same box converted into UIKit screen coordinates.
    let screenBoundingBox: CGRect

    /// Approximate size of the selected mask compared with the full image.
    let areaFraction: Float

    /// Debug image. Useful for showing the selected object mask on screen.
    let maskPreviewImage: UIImage?
}

enum SAMAnchorMath {
    /// Convert a UIKit tap point into Kida's normalized point format.
    ///
    /// UIKit view coordinates:
    /// - x: left -> right
    /// - y: top -> bottom
    ///
    /// Kida/SAM normalized coordinates:
    /// - x: left -> right
    /// - y: bottom -> top
    static func normalizedTargetPoint(
        tapInView: CGPoint,
        viewSize: CGSize
    ) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        return CGPoint(
            x: clamp(tapInView.x / viewSize.width),
            y: clamp(1 - (tapInView.y / viewSize.height))
        )
    }

    /// Convert SAM's normalized centroid into a UIKit screen point.
    static func screenPoint(
        fromNormalizedPoint point: CGPoint,
        viewSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: clamp(point.x) * viewSize.width,
            y: (1 - clamp(point.y)) * viewSize.height
        )
    }

    /// Convert SAM's normalized bounding box into a UIKit screen rect.
    static func screenRect(
        fromNormalizedBoundingBox boundingBox: CGRect,
        viewSize: CGSize
    ) -> CGRect {
        let minX = clamp(boundingBox.minX)
        let maxX = clamp(boundingBox.maxX)
        let minY = clamp(boundingBox.minY)
        let maxY = clamp(boundingBox.maxY)

        return CGRect(
            x: minX * viewSize.width,
            y: (1 - maxY) * viewSize.height,
            width: max(0, maxX - minX) * viewSize.width,
            height: max(0, maxY - minY) * viewSize.height
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

/*
 Example use inside an AR screen:

 let example = SAMUsageExample()
 await example.warmUpSAM()

 let frame = arView.session.currentFrame
 let result = await example.segmentTappedObject(
     pixelBuffer: frame.capturedImage,
     tapInView: tapLocation,
     viewSize: arView.bounds.size,
     includePreview: true
 )

 // For 2D UI:
 imageView.image = result?.maskPreviewImage
 overlayView.frame = result?.screenBoundingBox ?? .zero

 // For AR:
 // 1. Use result.screenAnchorPoint as the raycast point.
 // 2. Raycast from the ARView into the real world.
 // 3. Place the eyes and mouth at the raycast result.
 */
