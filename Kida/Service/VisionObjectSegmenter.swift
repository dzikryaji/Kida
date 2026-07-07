import CoreVideo
import Foundation
import UIKit
import Vision

/// Wraps a `CVPixelBuffer` so it can cross an `async` boundary. CVPixelBuffer
/// itself isn't Sendable, but in practice each buffer is only touched by one
/// task at a time here, so this is a deliberate, narrow escape hatch.
struct PixelBufferReference: @unchecked Sendable {
    let value: CVPixelBuffer
}

protocol ObjectSegmenting: Sendable {
    func prepare() async

    func segment(
        pixelBuffer: PixelBufferReference,
        targetPoint: CGPoint?,
        includePreview: Bool
    ) async -> ObjectSegmentation?
}

extension ObjectSegmenting {
    func prepare() async {}
}

final class VisionObjectSegmenter: ObjectSegmenting, @unchecked Sendable {
    func segment(
        pixelBuffer: PixelBufferReference,
        targetPoint: CGPoint?,
        includePreview: Bool
    ) async -> ObjectSegmentation? {
        await Task.detached(priority: .userInitiated) {
            self.segmentSynchronously(
                pixelBuffer: pixelBuffer.value,
                targetPoint: targetPoint,
                includePreview: includePreview
            )
        }.value
    }

    private func segmentSynchronously(
        pixelBuffer: CVPixelBuffer,
        targetPoint: CGPoint?,
        includePreview: Bool
    ) -> ObjectSegmentation? {
        guard #available(iOS 17.0, *) else {
            return nil
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)

        do {
            try handler.perform([request])
            guard let observation = request.results?.first else {
                return nil
            }

            return bestSegmentation(
                from: observation,
                targetPoint: targetPoint,
                includePreview: includePreview
            )
        } catch {
            return nil
        }
    }

    @available(iOS 17.0, *)
    private func bestSegmentation(
        from observation: VNInstanceMaskObservation,
        targetPoint: CGPoint?,
        includePreview: Bool
    ) -> ObjectSegmentation? {
        let instanceLabels = Set(observation.allInstances.map { $0 })
        guard !instanceLabels.isEmpty else {
            return nil
        }

        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(mask, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let pixelFormat = CVPixelBufferGetPixelFormatType(mask)

        let stats: [Int: InstanceMaskStats]
        switch pixelFormat {
        case kCVPixelFormatType_OneComponent8:
            stats = statsFromUInt8Mask(
                baseAddress: baseAddress,
                width: width,
                height: height,
                rowBytes: rowBytes,
                validLabels: instanceLabels
            )
        case kCVPixelFormatType_OneComponent32Float:
            stats = statsFromFloatMask(
                baseAddress: baseAddress,
                width: width,
                height: height,
                rowBytes: rowBytes,
                validLabels: instanceLabels
            )
        default:
            return nil
        }

        guard !stats.isEmpty else {
            return nil
        }

        let target = targetPoint ?? CGPoint(x: 0.5, y: 0.5)
        let preferredLabel = targetPoint.flatMap {
            selectedLabelNearTarget(
                $0,
                baseAddress: baseAddress,
                width: width,
                height: height,
                rowBytes: rowBytes,
                pixelFormat: pixelFormat,
                validLabels: instanceLabels
            )
        }
        let candidates = stats.map { label, stats in
            let normalized = stats.normalized(width: width, height: height)
            return ObjectSegmentationCandidate(
                label: label,
                segmentation: ObjectSegmentation(
                    boundingBox: normalized.boundingBox,
                    centroid: normalized.centroid,
                    areaFraction: Float(stats.count) / Float(max(width * height, 1)),
                    selectedInstanceIndex: label,
                    instanceCount: instanceLabels.count,
                    maskPreviewImage: nil
                ),
                score: score(
                    normalized: normalized,
                    targetPoint: target,
                    isPreferredLabel: label == preferredLabel
                )
            )
        }

        let bestCandidate = candidates
            .sorted { lhs, rhs in lhs.score > rhs.score }
            .first

        guard let bestCandidate else {
            return nil
        }

        var segmentation = bestCandidate.segmentation
        if includePreview {
            segmentation.maskPreviewImage = makeMaskPreviewImage(
                baseAddress: baseAddress,
                width: width,
                height: height,
                rowBytes: rowBytes,
                pixelFormat: pixelFormat,
                selectedLabel: bestCandidate.label
            )
        }
        return segmentation
    }

    private func statsFromUInt8Mask(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        rowBytes: Int,
        validLabels: Set<Int>
    ) -> [Int: InstanceMaskStats] {
        var statsByLabel: [Int: InstanceMaskStats] = [:]

        for y in 0..<height {
            let row = baseAddress.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let label = Int(row[x])
                guard validLabels.contains(label) else {
                    continue
                }

                statsByLabel[label, default: InstanceMaskStats()].include(x: x, y: y)
            }
        }

        return statsByLabel
    }

    private func statsFromFloatMask(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        rowBytes: Int,
        validLabels: Set<Int>
    ) -> [Int: InstanceMaskStats] {
        var statsByLabel: [Int: InstanceMaskStats] = [:]

        for y in 0..<height {
            let row = baseAddress.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                let label = Int(row[x].rounded())
                guard validLabels.contains(label) else {
                    continue
                }

                statsByLabel[label, default: InstanceMaskStats()].include(x: x, y: y)
            }
        }

        return statsByLabel
    }

    private func score(
        normalized: NormalizedMaskStats,
        targetPoint: CGPoint,
        isPreferredLabel: Bool
    ) -> Float {
        let dx = normalized.centroid.x - targetPoint.x
        let dy = normalized.centroid.y - targetPoint.y
        let distance = sqrt((dx * dx) + (dy * dy))
        let closeness = max(0, 1 - Float(distance * 1.65))
        let area = Float(normalized.boundingBox.width * normalized.boundingBox.height)
        return (isPreferredLabel ? 3.0 : 0) + closeness + min(area * 1.2, 0.45)
    }

    private func selectedLabelNearTarget(
        _ targetPoint: CGPoint,
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        rowBytes: Int,
        pixelFormat: OSType,
        validLabels: Set<Int>
    ) -> Int? {
        guard width > 0, height > 0 else {
            return nil
        }

        let targetX = min(max(Int((targetPoint.x * CGFloat(width)).rounded()), 0), width - 1)
        let targetY = min(max(Int(((1 - targetPoint.y) * CGFloat(height)).rounded()), 0), height - 1)

        if let exactLabel = selectedLabelAt(
            x: targetX,
            y: targetY,
            baseAddress: baseAddress,
            width: width,
            height: height,
            rowBytes: rowBytes,
            pixelFormat: pixelFormat,
            validLabels: validLabels
        ) {
            return exactLabel
        }

        let searchRadius = max(3, min(width, height) / 18)
        var bestLabel: Int?
        var bestDistanceSquared = Int.max

        for radius in 1...searchRadius {
            for y in max(0, targetY - radius)...min(height - 1, targetY + radius) {
                for x in max(0, targetX - radius)...min(width - 1, targetX + radius) {
                    guard x == targetX - radius || x == targetX + radius || y == targetY - radius || y == targetY + radius,
                          let label = selectedLabelAt(
                            x: x,
                            y: y,
                            baseAddress: baseAddress,
                            width: width,
                            height: height,
                            rowBytes: rowBytes,
                            pixelFormat: pixelFormat,
                            validLabels: validLabels
                          ) else {
                        continue
                    }

                    let dx = x - targetX
                    let dy = y - targetY
                    let distanceSquared = (dx * dx) + (dy * dy)
                    if distanceSquared < bestDistanceSquared {
                        bestDistanceSquared = distanceSquared
                        bestLabel = label
                    }
                }
            }

            if bestLabel != nil {
                return bestLabel
            }
        }

        return nil
    }

    private func selectedLabelAt(
        x: Int,
        y: Int,
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        rowBytes: Int,
        pixelFormat: OSType,
        validLabels: Set<Int>
    ) -> Int? {
        guard x >= 0, x < width, y >= 0, y < height else {
            return nil
        }

        let label: Int
        switch pixelFormat {
        case kCVPixelFormatType_OneComponent8:
            let row = baseAddress.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            label = Int(row[x])
        case kCVPixelFormatType_OneComponent32Float:
            let row = baseAddress.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            label = Int(row[x].rounded())
        default:
            return nil
        }

        return validLabels.contains(label) ? label : nil
    }

    private func makeMaskPreviewImage(
        baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        rowBytes: Int,
        pixelFormat: OSType,
        selectedLabel: Int
    ) -> UIImage? {
        guard width > 0, height > 0 else {
            return nil
        }

        var output = [UInt8](repeating: 0, count: width * height * 4)
        let fill = (red: UInt8(182), green: UInt8(142), blue: UInt8(255), alpha: UInt8(92))
        let edge = (red: UInt8(255), green: UInt8(232), blue: UInt8(132), alpha: UInt8(180))

        func labelAt(x: Int, y: Int) -> Int {
            guard x >= 0, x < width, y >= 0, y < height else {
                return 0
            }

            switch pixelFormat {
            case kCVPixelFormatType_OneComponent8:
                let row = baseAddress.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                return Int(row[x])
            case kCVPixelFormatType_OneComponent32Float:
                let row = baseAddress.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                return Int(row[x].rounded())
            default:
                return 0
            }
        }

        for y in 0..<height {
            for x in 0..<width where labelAt(x: x, y: y) == selectedLabel {
                let offset = ((y * width) + x) * 4
                let isEdge = labelAt(x: x - 1, y: y) != selectedLabel
                    || labelAt(x: x + 1, y: y) != selectedLabel
                    || labelAt(x: x, y: y - 1) != selectedLabel
                    || labelAt(x: x, y: y + 1) != selectedLabel
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
}

private struct ObjectSegmentationCandidate {
    var label: Int
    var segmentation: ObjectSegmentation
    var score: Float
}

private struct InstanceMaskStats {
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

        let boundingBox = CGRect(
            x: normalizedMinX,
            y: 1 - normalizedMaxYFromTop,
            width: normalizedMaxX - normalizedMinX,
            height: normalizedMaxYFromTop - normalizedMinYFromTop
        )

        return NormalizedMaskStats(
            boundingBox: boundingBox,
            centroid: CGPoint(x: centroidX, y: 1 - centroidYFromTop)
        )
    }
}

private struct NormalizedMaskStats {
    var boundingBox: CGRect
    var centroid: CGPoint
}
