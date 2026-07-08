import UIKit

/// Turns a photo into a die-cut sticker via the Mac server (BiRefNet).
///
/// NOTE: the on-device cutout (Apple Vision / SAM 2) path is intentionally NOT wired on this
/// branch. It depends on the shared segmentation engine your friend owns on `main`
/// (`SAM2ObjectSegmenter` / `VisionObjectSegmenter`), whose API differs from the sandbox's.
/// Until that's reconciled, the sticker uses the Mac `POST /object/sticker` tier when reachable
/// and returns nil otherwise. The full on-device implementation lives on `andrian/vision-asr-tts`.
///
/// ```swift
/// let sticker = await StickerService().makeSticker(from: photo)   // UIImage? on transparency
/// ```
final class StickerService {
    private let remote: RemoteStickerProvider

    init(remoteConfiguration: MacVLMConfiguration? = MacVLMConfiguration.load()) {
        self.remote = RemoteStickerProvider(configuration: remoteConfiguration)
    }

    /// Returns a die-cut sticker from the Mac server (BiRefNet) if reachable, else nil.
    /// `targetBox`/`focusPoint` are accepted for API stability; they drove the on-device
    /// crop that's deferred until the on-device segmenter is reconciled with `main`'s.
    func makeSticker(from image: UIImage, targetBox: CGRect? = nil, focusPoint: CGPoint? = nil) async -> UIImage? {
        guard remote.isAvailable else { return nil }
        return try? await remote.sticker(from: image)
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
