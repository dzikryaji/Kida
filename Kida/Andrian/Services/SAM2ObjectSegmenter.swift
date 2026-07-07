import CoreImage
import CoreML
import CoreVideo
import Foundation
import UIKit

final class HybridObjectSegmenter: ObjectSegmenting, @unchecked Sendable {
    private let primary: ObjectSegmenting
    private let fallback: ObjectSegmenting

    init(
        primary: ObjectSegmenting = SAM2ObjectSegmenter(),
        fallback: ObjectSegmenting = VisionObjectSegmenter()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    func prepare() async {
        await primary.prepare()
    }

    func segment(
        pixelBuffer: PixelBufferReference,
        targetPoint: CGPoint?,
        includePreview: Bool
    ) async -> ObjectSegmentation? {
        guard !Task.isCancelled else {
            return nil
        }

        if targetPoint != nil,
           let segmentation = await primary.segment(
            pixelBuffer: pixelBuffer,
            targetPoint: targetPoint,
            includePreview: includePreview
           ) {
            return segmentation
        }

        guard !Task.isCancelled else {
            return nil
        }

        return await fallback.segment(
            pixelBuffer: pixelBuffer,
            targetPoint: targetPoint,
            includePreview: includePreview
        )
    }
}

final class SAM2ObjectSegmenter: ObjectSegmenting, @unchecked Sendable {
    private let runtime = SAM2Runtime()

    func prepare() async {
        guard #available(iOS 17.0, *) else {
            return
        }

        await runtime.prepare()
    }

    func segment(
        pixelBuffer: PixelBufferReference,
        targetPoint: CGPoint?,
        includePreview: Bool
    ) async -> ObjectSegmentation? {
        guard #available(iOS 17.0, *),
              let targetPoint else {
            return nil
        }

        return await runtime.segment(
            pixelBuffer: pixelBuffer.value,
            targetPoint: targetPoint,
            includePreview: includePreview
        )
    }
}

@available(iOS 17.0, *)
private actor SAM2Runtime {
    private let inputSize = 1024
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var models: SAM2Models?
    private var didFailToLoadModels = false

    func prepare() {
        guard !didFailToLoadModels else {
            return
        }

        do {
            _ = try loadModelsIfNeeded()
        } catch {
            didFailToLoadModels = true
        }
    }

    func segment(
        pixelBuffer: CVPixelBuffer,
        targetPoint: CGPoint,
        includePreview: Bool
    ) -> ObjectSegmentation? {
        guard !didFailToLoadModels,
              !Task.isCancelled else {
            return nil
        }

        do {
            let models = try loadModelsIfNeeded()
            guard !Task.isCancelled else {
                return nil
            }

            let modelInput = try makeModelInput(from: pixelBuffer)
            guard !Task.isCancelled else {
                return nil
            }

            let imageFeatures = try models.imageEncoder.prediction(
                from: SAMFeatureProvider(values: [
                    "image": MLFeatureValue(pixelBuffer: modelInput)
                ])
            )
            guard !Task.isCancelled else {
                return nil
            }

            let promptFeatures = try models.promptEncoder.prediction(
                from: SAMFeatureProvider(values: [
                    "points": MLFeatureValue(multiArray: try makePointArray(from: targetPoint)),
                    "labels": MLFeatureValue(multiArray: try makeLabelArray())
                ])
            )

            guard let imageEmbedding = imageFeatures.featureValue(for: "image_embedding")?.multiArrayValue,
                  let feats0 = imageFeatures.featureValue(for: "feats_s0")?.multiArrayValue,
                  let feats1 = imageFeatures.featureValue(for: "feats_s1")?.multiArrayValue,
                  let sparseEmbedding = promptFeatures.featureValue(for: "sparse_embeddings")?.multiArrayValue,
                  let denseEmbedding = promptFeatures.featureValue(for: "dense_embeddings")?.multiArrayValue else {
                return nil
            }
            guard !Task.isCancelled else {
                return nil
            }

            let maskFeatures = try models.maskDecoder.prediction(
                from: SAMFeatureProvider(values: [
                    "image_embedding": MLFeatureValue(multiArray: imageEmbedding),
                    "sparse_embedding": MLFeatureValue(multiArray: sparseEmbedding),
                    "dense_embedding": MLFeatureValue(multiArray: denseEmbedding),
                    "feats_s0": MLFeatureValue(multiArray: feats0),
                    "feats_s1": MLFeatureValue(multiArray: feats1)
                ])
            )
            guard !Task.isCancelled else {
                return nil
            }

            guard let masks = maskFeatures.featureValue(for: "low_res_masks")?.multiArrayValue,
                  let scores = maskFeatures.featureValue(for: "scores")?.multiArrayValue else {
                return nil
            }

            return makeSegmentation(
                from: masks,
                bestMaskIndex: bestMaskIndex(from: scores),
                includePreview: includePreview
            )
        } catch {
            didFailToLoadModels = models == nil
            return nil
        }
    }

    private func loadModelsIfNeeded() throws -> SAM2Models {
        if let models {
            return models
        }

        let bundle = Bundle.main
        guard let imageEncoderURL = bundle.url(
            forResource: "SAM2_1SmallImageEncoderFLOAT16",
            withExtension: "mlmodelc"
        ),
              let promptEncoderURL = bundle.url(
                forResource: "SAM2_1SmallPromptEncoderFLOAT16",
                withExtension: "mlmodelc"
              ),
              let maskDecoderURL = bundle.url(
                forResource: "SAM2_1SmallMaskDecoderFLOAT16",
                withExtension: "mlmodelc"
              ) else {
            throw SAM2Error.modelNotFound
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine

        let loaded = SAM2Models(
            imageEncoder: try MLModel(contentsOf: imageEncoderURL, configuration: configuration),
            promptEncoder: try MLModel(contentsOf: promptEncoderURL, configuration: configuration),
            maskDecoder: try MLModel(contentsOf: maskDecoderURL, configuration: configuration)
        )
        models = loaded
        return loaded
    }

    private func makeModelInput(from pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            inputSize,
            inputSize,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &output
        )

        guard status == kCVReturnSuccess,
              let output else {
            throw SAM2Error.pixelBufferCreationFailed
        }

        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let originAligned = oriented.transformed(
            by: CGAffineTransform(
                translationX: -oriented.extent.minX,
                y: -oriented.extent.minY
            )
        )
        let scaled = originAligned.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(inputSize) / max(originAligned.extent.width, 1),
                y: CGFloat(inputSize) / max(originAligned.extent.height, 1)
            )
        )

        ciContext.render(
            scaled,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: inputSize, height: inputSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return output
    }

    private func makePointArray(from targetPoint: CGPoint) throws -> MLMultiArray {
        let points = try MLMultiArray(shape: [1, 1, 2], dataType: .float32)
        let x = Float(clamped(targetPoint.x) * CGFloat(inputSize))
        let y = Float((1 - clamped(targetPoint.y)) * CGFloat(inputSize))

        points[[0, 0, 0] as [NSNumber]] = NSNumber(value: x)
        points[[0, 0, 1] as [NSNumber]] = NSNumber(value: y)
        return points
    }

    private func makeLabelArray() throws -> MLMultiArray {
        let labels = try MLMultiArray(shape: [1, 1], dataType: .int32)
        labels[[0, 0] as [NSNumber]] = NSNumber(value: 1)
        return labels
    }

    private func bestMaskIndex(from scores: MLMultiArray) -> Int {
        guard scores.count > 0 else {
            return 0
        }

        var bestIndex = 0
        var bestScore = -Float.greatestFiniteMagnitude

        for index in 0..<min(scores.count, 3) {
            let score = scores[index].floatValue
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func makeSegmentation(
        from masks: MLMultiArray,
        bestMaskIndex: Int,
        includePreview: Bool
    ) -> ObjectSegmentation? {
        guard masks.shape.count == 4 else {
            return nil
        }

        let height = masks.shape[2].intValue
        let width = masks.shape[3].intValue
        guard width > 0, height > 0 else {
            return nil
        }

        var stats = SAMMaskStats()
        var selectedPixels = includePreview ? [Bool](repeating: false, count: width * height) : []

        for y in 0..<height {
            for x in 0..<width {
                let value = masks[[0, bestMaskIndex, y, x] as [NSNumber]].floatValue
                guard value > 0 else {
                    continue
                }

                stats.include(x: x, y: y)
                if includePreview {
                    selectedPixels[(y * width) + x] = true
                }
            }
        }

        guard stats.count > max(12, (width * height) / 1_200) else {
            return nil
        }

        let normalized = stats.normalized(width: width, height: height)
        return ObjectSegmentation(
            boundingBox: normalized.boundingBox,
            centroid: normalized.centroid,
            areaFraction: Float(stats.count) / Float(max(width * height, 1)),
            selectedInstanceIndex: bestMaskIndex,
            instanceCount: min(masks.shape[1].intValue, 3),
            maskPreviewImage: includePreview ? makeMaskPreviewImage(
                selectedPixels: selectedPixels,
                width: width,
                height: height
            ) : nil
        )
    }

    private func makeMaskPreviewImage(
        selectedPixels: [Bool],
        width: Int,
        height: Int
    ) -> UIImage? {
        guard selectedPixels.count == width * height else {
            return nil
        }

        var output = [UInt8](repeating: 0, count: width * height * 4)
        let fill = (red: UInt8(182), green: UInt8(142), blue: UInt8(255), alpha: UInt8(92))
        let edge = (red: UInt8(255), green: UInt8(232), blue: UInt8(132), alpha: UInt8(190))

        func isSelected(x: Int, y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else {
                return false
            }
            return selectedPixels[(y * width) + x]
        }

        for y in 0..<height {
            for x in 0..<width where isSelected(x: x, y: y) {
                let offset = ((y * width) + x) * 4
                let isEdge = !isSelected(x: x - 1, y: y)
                    || !isSelected(x: x + 1, y: y)
                    || !isSelected(x: x, y: y - 1)
                    || !isSelected(x: x, y: y + 1)
                let color = isEdge ? edge : fill
                output[offset] = color.red
                output[offset + 1] = color.green
                output[offset + 2] = color.blue
                output[offset + 3] = color.alpha
            }
        }

        let data = Data(output)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return UIImage(cgImage: image)
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

@available(iOS 17.0, *)
private struct SAM2Models {
    let imageEncoder: MLModel
    let promptEncoder: MLModel
    let maskDecoder: MLModel
}

private final class SAMFeatureProvider: MLFeatureProvider {
    private let values: [String: MLFeatureValue]

    var featureNames: Set<String> {
        Set(values.keys)
    }

    init(values: [String: MLFeatureValue]) {
        self.values = values
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        values[featureName]
    }
}

private struct SAMMaskStats {
    var minX = Int.max
    var minY = Int.max
    var maxX = Int.min
    var maxY = Int.min
    var sumX = 0
    var sumY = 0
    var count = 0

    mutating func include(x: Int, y: Int) {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
        sumX += x
        sumY += y
        count += 1
    }

    func normalized(width: Int, height: Int) -> NormalizedMaskStats {
        let safeWidth = max(width, 1)
        let safeHeight = max(height, 1)
        let normalizedMinX = CGFloat(minX) / CGFloat(safeWidth)
        let normalizedMaxX = CGFloat(maxX + 1) / CGFloat(safeWidth)
        let normalizedMinYFromTop = CGFloat(minY) / CGFloat(safeHeight)
        let normalizedMaxYFromTop = CGFloat(maxY + 1) / CGFloat(safeHeight)
        let centroidX = CGFloat(sumX) / CGFloat(max(count, 1)) / CGFloat(safeWidth)
        let centroidYFromTop = CGFloat(sumY) / CGFloat(max(count, 1)) / CGFloat(safeHeight)

        return NormalizedMaskStats(
            boundingBox: CGRect(
                x: normalizedMinX,
                y: 1 - normalizedMaxYFromTop,
                width: normalizedMaxX - normalizedMinX,
                height: normalizedMaxYFromTop - normalizedMinYFromTop
            ),
            centroid: CGPoint(x: centroidX, y: 1 - centroidYFromTop)
        )
    }
}

private struct NormalizedMaskStats {
    var boundingBox: CGRect
    var centroid: CGPoint
}

private enum SAM2Error: Error {
    case modelNotFound
    case pixelBufferCreationFailed
}
