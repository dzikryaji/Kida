import CoreImage
import CoreML
import UIKit
import Vision

struct PixelBufferReference: @unchecked Sendable {
    let value: CVPixelBuffer
}

protocol ObjectDetecting: Sendable {
    func detect(pixelBuffer: PixelBufferReference) async -> DetectedObject
}

final class VisionObjectDetector: ObjectDetecting, @unchecked Sendable {
    private let maximumCapturedImageDimension: CGFloat = 720
    private let imageContext = CIContext()
    private lazy var yoloModels: [VNCoreMLModel] = [
        loadYOLOModel(named: "YOLOv3TinyInt8LUT"),
        loadYOLOModel(named: "YOLOv3Int8LUT")
    ].compactMap { $0 }

    func detect(pixelBuffer: PixelBufferReference) async -> DetectedObject {
        await Task.detached(priority: .userInitiated) { [self] in
            detectSynchronously(pixelBuffer: pixelBuffer.value)
        }.value
    }

    private func detectSynchronously(pixelBuffer: CVPixelBuffer) -> DetectedObject {
        if #available(iOS 17.0, *) {
            if let detectedObject = detectWithCoreML(pixelBuffer: pixelBuffer) {
                return detectedObject
            }

            return classifyWithVision(pixelBuffer: pixelBuffer)
        }

        return DetectedObject(
            label: "object",
            confidence: 0,
            capturedImage: makeImage(from: pixelBuffer),
            boundingBox: nil,
            segmentation: nil,
            alternatives: [],
            visualContext: nil,
            faceStyle: nil
        )
    }

    @available(iOS 17.0, *)
    private func detectWithCoreML(pixelBuffer: CVPixelBuffer) -> DetectedObject? {
        for model in yoloModels {
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)

            do {
                try handler.perform([request])
                let observations = (request.results as? [VNRecognizedObjectObservation]) ?? []
                let candidates = observations
                    .compactMap { observation -> ObjectDetectionCandidate? in
                        guard let label = observation.labels.first,
                              label.confidence >= 0.16 else {
                            return nil
                        }

                        return ObjectDetectionCandidate(
                            label: ObjectLabelNormalizer.normalize(label.identifier),
                            confidence: label.confidence,
                            boundingBox: observation.boundingBox,
                            centerScore: centerScore(for: observation.boundingBox, confidence: label.confidence)
                        )
                    }
                    .sorted { lhs, rhs in
                        lhs.centerScore > rhs.centerScore
                    }

                guard let best = candidates.first else {
                    continue
                }

                let alternatives = candidates
                    .prefix(6)
                    .map(\.label)
                    .reduce(into: [String]()) { result, label in
                        if !result.contains(label) {
                            result.append(label)
                        }
                    }

                return DetectedObject(
                    label: best.label,
                    confidence: best.confidence,
                    capturedImage: makeImage(from: pixelBuffer),
                    boundingBox: best.boundingBox,
                    segmentation: nil,
                    alternatives: alternatives,
                    visualContext: nil,
                    faceStyle: nil
                )
            } catch {
                continue
            }
        }

        return nil
    }

    @available(iOS 17.0, *)
    private func classifyWithVision(pixelBuffer: CVPixelBuffer) -> DetectedObject {
        let request = VNClassifyImageRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)

        do {
            try handler.perform([request])
            let observations = request.results ?? []
            let filtered = observations
                .filter { $0.confidence > 0.02 }
                .prefix(6)

            if let best = filtered.first {
                let label = ObjectLabelNormalizer.normalize(best.identifier)
                let alternatives = filtered
                    .map { ObjectLabelNormalizer.normalize($0.identifier) }
                    .reduce(into: [String]()) { result, label in
                        if !result.contains(label) {
                            result.append(label)
                        }
                    }

                return DetectedObject(
                    label: label,
                    confidence: best.confidence,
                    capturedImage: makeImage(from: pixelBuffer),
                    boundingBox: nil,
                    segmentation: nil,
                    alternatives: alternatives,
                    visualContext: nil,
                    faceStyle: nil
                )
            }
        } catch {
            // Keep the AR flow moving. The UI will show the fallback label and let the child continue.
        }

        return DetectedObject(
            label: "object",
            confidence: 0,
            capturedImage: makeImage(from: pixelBuffer),
            boundingBox: nil,
            segmentation: nil,
            alternatives: [],
            visualContext: nil,
            faceStyle: nil
        )
    }

    private func makeImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let maxDimension = max(ciImage.extent.width, ciImage.extent.height)
        let scale = maxDimension > maximumCapturedImageDimension ? maximumCapturedImageDimension / maxDimension : 1
        let outputImage = scale < 1
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage

        guard let cgImage = imageContext.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: 1, orientation: .right)
    }

    private func loadYOLOModel(named resourceName: String) -> VNCoreMLModel? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc") else {
            return nil
        }

        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: url, configuration: configuration)
            return try VNCoreMLModel(for: model)
        } catch {
            return nil
        }
    }

    private func centerScore(for boundingBox: CGRect, confidence: Float) -> Float {
        let center = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
        let distanceFromCenter = hypot(center.x - 0.5, center.y - 0.5)
        let area = boundingBox.width * boundingBox.height
        let targetBonus = max(0, 1 - (distanceFromCenter * 1.65))
        return confidence + Float(targetBonus * 0.55) + Float(min(area, 0.35) * 0.2)
    }
}

private struct ObjectDetectionCandidate {
    var label: String
    var confidence: Float
    var boundingBox: CGRect
    var centerScore: Float
}
