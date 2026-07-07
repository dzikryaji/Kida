import CoreImage
import Foundation
import ImageIO
import UIKit
import Vision

final class ImageContextExtractor: @unchecked Sendable {
    private let ciContext = CIContext()

    func makeFastContext(for detectedObject: DetectedObject) -> String {
        makeContext(for: detectedObject, includeOCR: false)
    }

    func makeDetailedContext(for detectedObject: DetectedObject) async -> String {
        await Task.detached(priority: .utility) {
            let extractor = ImageContextExtractor()
            return extractor.makeContext(for: detectedObject, includeOCR: true)
        }.value
    }

    private func makeContext(for detectedObject: DetectedObject, includeOCR: Bool) -> String {
        var lines = [
            "Detected object: \(detectedObject.label)",
            "Detector confidence: \(Self.percentString(detectedObject.confidence))"
        ]

        if !detectedObject.alternatives.isEmpty {
            lines.append("Other possible labels: \(detectedObject.alternatives.joined(separator: ", "))")
        }

        if let segmentation = detectedObject.segmentation {
            lines.append("Foreground segmentation: selected instance \(segmentation.selectedInstanceIndex) of \(segmentation.instanceCount)")
            lines.append("Segmented object area: \(Self.percentString(segmentation.areaFraction)) of the frame")
        } else {
            lines.append("Foreground segmentation: not available")
        }

        if let boundingBox = detectedObject.boundingBox {
            lines.append("Object position in camera frame: \(Self.positionDescription(for: boundingBox))")
            lines.append("Object size in camera frame: \(Self.sizeDescription(for: boundingBox))")
        } else {
            lines.append("Object position in camera frame: no bounding box available")
        }

        guard let image = detectedObject.capturedImage else {
            lines.append("Camera image: not available")
            return lines.joined(separator: "\n")
        }

        if let cgImage = makeCGImage(from: image) {
            lines.append("Camera image size: \(cgImage.width)x\(cgImage.height) pixels")
        } else {
            lines.append("Camera image size: unavailable")
        }

        if let colorDescription = averageColorDescription(in: image, boundingBox: detectedObject.boundingBox) {
            lines.append("Approximate visible color: \(colorDescription)")
        }

        if let faceStyle = detectedObject.faceStyle,
           let colorDescription = faceStyle.objectColorDescription {
            lines.append("Face contrast decision: object looks \(colorDescription), brightness \(Self.brightnessString(faceStyle.objectBrightness))")
        }

        if includeOCR {
            let recognizedText = recognizeText(in: image)
            if recognizedText.isEmpty {
                lines.append("Readable text on object/frame: none detected")
            } else {
                lines.append("Readable text on object/frame: \(recognizedText.joined(separator: " | "))")
            }
        } else {
            lines.append("Readable text on object/frame: not checked during fast scan")
        }

        return lines.joined(separator: "\n")
    }

    private func recognizeText(in image: UIImage) -> [String] {
        guard let cgImage = makeCGImage(from: image) else {
            return []
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.025

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(image.imageOrientation),
            options: [:]
        )

        do {
            try handler.perform([request])
            let strings = (request.results ?? [])
                .prefix(4)
                .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            return strings.reduce(into: [String]()) { result, text in
                if !result.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                    result.append(text)
                }
            }
        } catch {
            return []
        }
    }

    private func averageColorDescription(in image: UIImage, boundingBox: CGRect?) -> String? {
        guard let ciImage = CIImage(image: image) else {
            return nil
        }

        let inputExtent = analysisExtent(for: ciImage.extent, boundingBox: boundingBox)
        guard !inputExtent.isNull, !inputExtent.isEmpty else {
            return nil
        }

        let filter = CIFilter(name: "CIAreaAverage")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgRect: inputExtent), forKey: kCIInputExtentKey)

        guard let outputImage = filter?.outputImage else {
            return nil
        }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let outputBounds = CGRect(x: 0, y: 0, width: 1, height: 1)

        bitmap.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            ciContext.render(
                outputImage,
                toBitmap: baseAddress,
                rowBytes: 4,
                bounds: outputBounds,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        return Self.colorName(
            red: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: CGFloat(bitmap[3]) / 255
        )
    }

    private func analysisExtent(for imageExtent: CGRect, boundingBox: CGRect?) -> CGRect {
        guard let boundingBox else {
            return imageExtent
        }

        let candidate = CGRect(
            x: imageExtent.minX + boundingBox.minX * imageExtent.width,
            y: imageExtent.minY + boundingBox.minY * imageExtent.height,
            width: boundingBox.width * imageExtent.width,
            height: boundingBox.height * imageExtent.height
        )

        return candidate.intersection(imageExtent)
    }

    private func makeCGImage(from image: UIImage) -> CGImage? {
        if let cgImage = image.cgImage {
            return cgImage
        }

        guard let ciImage = CIImage(image: image) else {
            return nil
        }

        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    private static func percentString(_ confidence: Float) -> String {
        "\(Int((confidence * 100).rounded()))%"
    }

    private static func brightnessString(_ brightness: CGFloat?) -> String {
        guard let brightness else {
            return "unknown"
        }

        return String(format: "%.2f", brightness)
    }

    private static func positionDescription(for boundingBox: CGRect) -> String {
        let horizontal: String
        if boundingBox.midX < 0.34 {
            horizontal = "left"
        } else if boundingBox.midX > 0.66 {
            horizontal = "right"
        } else {
            horizontal = "center"
        }

        let vertical: String
        if boundingBox.midY < 0.34 {
            vertical = "bottom"
        } else if boundingBox.midY > 0.66 {
            vertical = "top"
        } else {
            vertical = "middle"
        }

        return "\(vertical) \(horizontal)"
    }

    private static func sizeDescription(for boundingBox: CGRect) -> String {
        let area = boundingBox.width * boundingBox.height
        switch area {
        case 0.28...:
            return "large"
        case 0.10..<0.28:
            return "medium"
        default:
            return "small"
        }
    }

    private static func colorName(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> String {
        guard alpha > 0.05 else {
            return "transparent or unclear"
        }

        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let brightness = maxValue
        let saturation = maxValue == 0 ? 0 : (maxValue - minValue) / maxValue

        if brightness < 0.14 {
            return "very dark"
        }

        if saturation < 0.12 {
            if brightness > 0.86 {
                return "white or very light"
            }

            return brightness < 0.45 ? "dark gray" : "light gray"
        }

        let hue = hueDegrees(red: red, green: green, blue: blue, maxValue: maxValue, minValue: minValue)
        switch hue {
        case 0..<18, 342...360:
            return "red"
        case 18..<45:
            return brightness < 0.55 ? "brown" : "orange"
        case 45..<70:
            return "yellow"
        case 70..<165:
            return "green"
        case 165..<205:
            return "cyan"
        case 205..<260:
            return "blue"
        case 260..<310:
            return "purple"
        default:
            return "pink"
        }
    }

    private static func hueDegrees(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        maxValue: CGFloat,
        minValue: CGFloat
    ) -> CGFloat {
        let delta = maxValue - minValue
        guard delta > 0 else {
            return 0
        }

        let hue: CGFloat
        if maxValue == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == green {
            hue = ((blue - red) / delta) + 2
        } else {
            hue = ((red - green) / delta) + 4
        }

        let degrees = hue * 60
        return degrees < 0 ? degrees + 360 : degrees
    }
}

private extension CGImagePropertyOrientation {
    init(_ imageOrientation: UIImage.Orientation) {
        switch imageOrientation {
        case .up:
            self = .up
        case .upMirrored:
            self = .upMirrored
        case .down:
            self = .down
        case .downMirrored:
            self = .downMirrored
        case .left:
            self = .left
        case .leftMirrored:
            self = .leftMirrored
        case .right:
            self = .right
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
