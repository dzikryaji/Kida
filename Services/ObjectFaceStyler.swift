import CoreImage
import UIKit

final class ObjectFaceStyler: @unchecked Sendable {
    private let ciContext = CIContext()

    func style(for detectedObject: DetectedObject) -> FaceVisualStyle {
        guard let image = detectedObject.capturedImage,
              let average = averageColor(in: image, boundingBox: detectedObject.boundingBox) else {
            return .standard
        }

        return FaceVisualStyle.contrastingForObject(
            colorDescription: colorName(red: average.red, green: average.green, blue: average.blue),
            brightness: average.brightness
        )
    }

    private func averageColor(in image: UIImage, boundingBox: CGRect?) -> AverageColor? {
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
        bitmap.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            ciContext.render(
                outputImage,
                toBitmap: baseAddress,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }

        let red = CGFloat(bitmap[0]) / 255
        let green = CGFloat(bitmap[1]) / 255
        let blue = CGFloat(bitmap[2]) / 255
        let alpha = CGFloat(bitmap[3]) / 255
        guard alpha > 0.05 else {
            return nil
        }

        let brightness = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return AverageColor(red: red, green: green, blue: blue, brightness: brightness)
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

    private func colorName(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
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

    private func hueDegrees(
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

private struct AverageColor {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var brightness: CGFloat
}
