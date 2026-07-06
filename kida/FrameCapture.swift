//
//  FrameCapture.swift
//  kida
//
//  Created by Imelda Damayanti on 06/07/26.
//

import ARKit
import RealityKit
import CoreImage
import UIKit

enum FrameCapture {

    private static let ciContext = CIContext()

    /// One full frame from the live camera, oriented to portrait.
    ///
    /// `ARFrame.capturedImage` is a CVPixelBuffer in landscape (camera-native)
    /// orientation, so it must be rotated before the VLM sees it — otherwise the
    /// model reads a sideways scene.
    static func snapshot(from arView: ARView) -> UIImage? {
        guard let frame = arView.session.currentFrame else { return nil }

        let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// A square crop centred on the tapped point, so the VLM focuses on the
    /// object the user tapped instead of the whole scene.
    ///
    /// - Parameters:
    ///   - tapPoint: tap location in ARView coordinates.
    ///   - viewSize: the ARView's bounds size (to map the tap into image space).
    ///   - boxFraction: crop side length as a fraction of the image's shorter edge.
    static func snapshot(
        from arView: ARView,
        around tapPoint: CGPoint,
        viewSize: CGSize,
        boxFraction: CGFloat = 0.4
    ) -> UIImage? {
        guard let full = snapshot(from: arView), let cg = full.cgImage,
              viewSize.width > 0, viewSize.height > 0 else { return nil }

        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)

        // Map the tap (view space) into image space via normalized coordinates.
        let nx = (tapPoint.x / viewSize.width).clamped(to: 0...1)
        let ny = (tapPoint.y / viewSize.height).clamped(to: 0...1)
        let centerX = nx * imgW
        let centerY = ny * imgH

        let side = min(imgW, imgH) * boxFraction
        var originX = centerX - side / 2
        var originY = centerY - side / 2
        originX = originX.clamped(to: 0...(imgW - side))
        originY = originY.clamped(to: 0...(imgH - side))

        let rect = CGRect(x: originX, y: originY, width: side, height: side)
        guard let cropped = cg.cropping(to: rect) else { return full }
        return UIImage(cgImage: cropped)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
