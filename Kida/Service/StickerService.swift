import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

/// Turns a photo into a die-cut sticker, tiered:
///  - **Mac reachable** → `POST /object/sticker` runs BiRefNet on the Mac (best quality).
///  - **on-device (default)** → Apple Vision foreground mask (`VNGenerateForegroundInstanceMaskRequest`),
///    zero bundled model, fast, whole-object.
///  - **fallback** → SAM 2 (point-promptable) if Vision returns nothing.
///
/// ```swift
/// let stickers = StickerService()
/// let sticker = await stickers.makeSticker(from: photo)   // UIImage? on transparency
/// ```
final class StickerService {
    private let visionSegmenter = VisionObjectSegmenter()
    private let samSegmenter = SAM2ObjectSegmenter()
    private let remote: RemoteStickerProvider

    init(remoteConfiguration: MacVLMConfiguration? = MacVLMConfiguration.load()) {
        self.remote = RemoteStickerProvider(configuration: remoteConfiguration)
    }

    /// Warms up the SAM 2 fallback models. Optional (Apple Vision needs no warm-up).
    func prepare() async {
        await samSegmenter.prepare()
    }

    /// Makes a sticker: Mac BiRefNet if reachable, else on-device Apple Vision, else SAM 2.
    /// - Parameters:
    ///   - image: the source photo.
    ///   - targetBox: the framed reticle, normalized 0...1 **bottom-left origin**. When given,
    ///     the on-device Vision path crops to it (+margin) first, so hands/clutter *outside*
    ///     the box are excluded before segmentation. `nil` = whole frame (no crop).
    ///   - focusPoint: on-device targeting — point on the object, normalized 0...1 bottom-left.
    func makeSticker(from image: UIImage, targetBox: CGRect? = nil, focusPoint: CGPoint? = nil) async -> UIImage? {
        if remote.isAvailable, let sticker = try? await remote.sticker(from: image) {
            return sticker
        }
        if let vision = await appleVisionSticker(from: image, targetBox: targetBox, focusPoint: focusPoint) {
            return vision
        }
        return await samSegmenter.segmentObject(in: image, at: focusPoint, style: .sticker)?.cutout
    }

    /// On-device sticker with metadata (mask + bbox + coverage). Uses SAM 2 (the server tier
    /// returns a flat image). Use when placing the sticker in AR.
    func makeStickerResult(from image: UIImage, focusPoint: CGPoint? = nil) async -> SAMSegmentationResult? {
        await samSegmenter.segmentObject(in: image, at: focusPoint, style: .sticker)
    }

    // MARK: - Apple Vision on-device path

    private func appleVisionSticker(from image: UIImage, targetBox: CGRect?, focusPoint: CGPoint?) async -> UIImage? {
        guard let upright = Self.uprightCGImage(image) else { return nil }
        // Crop to the framed reticle first (if provided) so the hand/arm and clutter outside
        // the box are gone before Vision runs — the cutout is self-contained, so no remap.
        let cgImage = Self.cropped(upright, toTargetBox: targetBox)
        guard let segmentation = await visionSegmenter.segment(
                cgImage: cgImage,
                orientation: .up,
                targetPoint: nil,
                includePreview: false
              ),
              let mask = segmentation.maskImage else {
            return nil
        }
        return StickerCutout.make(
            from: cgImage,
            mask: mask,
            normalizedBox: segmentation.boundingBox,
            style: .sticker
        )
    }

    /// Crops to the target reticle (bottom-left normalized) + an 8% margin, converting to the
    /// CGImage's top-left pixel space. Returns the input unchanged if no usable box is given.
    private static func cropped(_ cgImage: CGImage, toTargetBox targetBox: CGRect?) -> CGImage {
        guard let targetBox else { return cgImage }
        let box = targetBox
            .insetBy(dx: -0.08 * targetBox.width, dy: -0.08 * targetBox.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0.05, box.height > 0.05 else { return cgImage }
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        // bottom-left normalized -> top-left pixel rect
        let topLeftMinY = 1 - (box.minY + box.height)
        let px = CGRect(x: box.minX * w, y: topLeftMinY * h, width: box.width * w, height: box.height * h).integral
        return cgImage.cropping(to: px) ?? cgImage
    }

    /// Bakes `UIImage.imageOrientation` into pixels so Vision + the cutout math see an upright image.
    private static func uprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    /// Upright, size-capped JPEG for upload — bakes orientation into pixels so the Mac
    /// (whose PIL/rembg won't apply an EXIF flag) receives a correctly-oriented image.
    static func uprightJPEGData(_ image: UIImage, maxDimension: CGFloat = 1536, quality: CGFloat = 0.9) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}

/// Shared sticker post-processing: cleans a low-res segmentation mask (fills enclosed holes
/// so dark low-contrast regions don't punch through), feathers the edge, applies it as
/// alpha, and — for `.sticker` — wraps the object in a white outline. Used by both the
/// Apple Vision and SAM 2 paths. Runs in CoreImage's bottom-left space to match the app's
/// `ObjectSegmentation.boundingBox` convention; the mask is read via its native pixel buffer
/// (top-left row order) so cleanup can't flip it.
enum StickerCutout {
    static func make(from imageCG: CGImage, mask: UIImage, normalizedBox: CGRect, style: CutoutStyle) -> UIImage? {
        guard let maskCG = mask.cgImage,
              let grid = maskGrid(from: maskCG) else {
            return nil
        }

        let width = CGFloat(imageCG.width)
        let height = CGFloat(imageCG.height)
        guard width > 0, height > 0 else {
            return nil
        }

        let filled = fillHoles(grid.pixels, width: grid.width, height: grid.height)
        guard let objectMaskCG = grayImage(from: filled, width: grid.width, height: grid.height) else {
            return nil
        }

        let imageCI = CIImage(cgImage: imageCG)
        let featherSigma = Double(width / CGFloat(max(grid.width, 1))) * 0.6
        let objectAlpha = scaledFeatheredMask(objectMaskCG, to: imageCI.extent, sigma: featherSigma)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: imageCI.extent)
        let object = blend(input: imageCI, background: clear, mask: objectAlpha)

        let finalImage: CIImage
        let cropNormalized: CGRect
        switch style {
        case .plain:
            finalImage = object
            cropNormalized = normalizedBox
        case .sticker:
            let borderRadius = max(3, grid.width / 42)
            let border = dilate(filled, width: grid.width, height: grid.height, radius: borderRadius)
            guard let borderMaskCG = grayImage(from: border, width: grid.width, height: grid.height) else {
                return nil
            }
            let borderAlpha = scaledFeatheredMask(borderMaskCG, to: imageCI.extent, sigma: featherSigma)
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: imageCI.extent)
            let silhouette = blend(input: white, background: clear, mask: borderAlpha)
            finalImage = object.composited(over: silhouette)
            let pad = CGFloat(borderRadius) / CGFloat(max(grid.width, 1))
            cropNormalized = normalizedBox.insetBy(dx: -pad, dy: -pad)
        }

        let boxRect = CGRect(
            x: cropNormalized.minX * width,
            y: cropNormalized.minY * height,
            width: cropNormalized.width * width,
            height: cropNormalized.height * height
        ).integral.intersection(imageCI.extent)
        let cropRect = (boxRect.isNull || boxRect.isEmpty) ? imageCI.extent : boxRect
        let cropped = finalImage.cropped(to: cropRect)

        let context = CIContext(options: [.cacheIntermediates: false])
        guard let rendered = context.createCGImage(cropped, from: cropped.extent) else {
            return nil
        }
        return UIImage(cgImage: rendered)
    }

    private static func blend(input: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = input
        filter.backgroundImage = background
        filter.maskImage = mask
        return filter.outputImage ?? input
    }

    private static func scaledFeatheredMask(_ maskCG: CGImage, to extent: CGRect, sigma: Double) -> CIImage {
        let mask = CIImage(cgImage: maskCG)
        let scaled = mask.transformed(by: CGAffineTransform(
            scaleX: extent.width / max(mask.extent.width, 1),
            y: extent.height / max(mask.extent.height, 1)
        ))
        guard sigma > 0.1 else { return scaled }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = scaled
        blur.radius = Float(sigma)
        return (blur.outputImage ?? scaled).cropped(to: extent)
    }

    private static func maskGrid(from maskCG: CGImage) -> (pixels: [Bool], width: Int, height: Int)? {
        let width = maskCG.width
        let height = maskCG.height
        guard width > 0, height > 0,
              let data = maskCG.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return nil
        }

        let bytesPerRow = maskCG.bytesPerRow
        let bytesPerPixel = max(maskCG.bitsPerPixel / 8, 1)
        var pixels = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                pixels[y * width + x] = ptr[row + x * bytesPerPixel] > 127
            }
        }
        return (pixels, width, height)
    }

    private static func fillHoles(_ pixels: [Bool], width: Int, height: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: pixels.count)
        var stack = [Int]()
        func push(_ x: Int, _ y: Int) {
            let i = y * width + x
            if !pixels[i] && !outside[i] {
                outside[i] = true
                stack.append(i)
            }
        }
        for x in 0..<width { push(x, 0); push(x, height - 1) }
        for y in 0..<height { push(0, y); push(width - 1, y) }
        while let i = stack.popLast() {
            let x = i % width
            let y = i / width
            if x > 0 { push(x - 1, y) }
            if x < width - 1 { push(x + 1, y) }
            if y > 0 { push(x, y - 1) }
            if y < height - 1 { push(x, y + 1) }
        }
        var out = pixels
        for i in 0..<pixels.count where !pixels[i] && !outside[i] { out[i] = true }
        return out
    }

    private static func dilate(_ pixels: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: pixels.count)
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] {
                let x0 = max(0, x - radius), x1 = min(width - 1, x + radius)
                let y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
                for ny in y0...y1 {
                    for nx in x0...x1 { out[ny * width + nx] = true }
                }
            }
        }
        return out
    }

    private static func grayImage(from pixels: [Bool], width: Int, height: Int) -> CGImage? {
        let bytes = pixels.map { $0 ? UInt8(255) : UInt8(0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// Calls the Mac server's `/object/sticker` (BiRefNet) endpoint.
struct RemoteStickerProvider {
    let configuration: MacVLMConfiguration?

    var isAvailable: Bool { configuration != nil }

    func sticker(from image: UIImage) async throws -> UIImage {
        guard let configuration else {
            throw RemoteStickerError.notConfigured
        }
        guard let jpeg = StickerService.uprightJPEGData(image) else {
            throw RemoteStickerError.encodingFailed
        }

        let url = configuration.baseURL.appendingPathComponent("object/sticker")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(configuration.timeout, 30)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = configuration.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            StickerRequest(image: StickerRequest.Image(mimeType: "image/jpeg", data: jpeg.base64EncodedString()))
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteStickerError.badStatus
        }
        let decoded = try JSONDecoder().decode(StickerResponse.self, from: data)
        guard let base64 = decoded.sticker?.data,
              let bytes = Data(base64Encoded: base64),
              let image = UIImage(data: bytes) else {
            throw RemoteStickerError.emptyResult
        }
        return image
    }
}

enum RemoteStickerError: Error {
    case notConfigured
    case encodingFailed
    case badStatus
    case emptyResult
}

private struct StickerRequest: Encodable {
    struct Image: Encodable {
        var mimeType: String
        var data: String
    }
    var image: Image
}

private struct StickerResponse: Decodable {
    struct Image: Decodable {
        var mimeType: String
        var data: String
    }
    var sticker: Image?
    var width: Int?
    var height: Int?
    var source: String?
}
