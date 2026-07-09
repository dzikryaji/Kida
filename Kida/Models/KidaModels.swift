import Foundation
import UIKit

struct DetectedObject: Identifiable, @unchecked Sendable {
    let id = UUID()
    var label: String
    var confidence: Float
    var capturedImage: UIImage?
    var boundingBox: CGRect?
    var segmentation: ObjectSegmentation?
    var alternatives: [String]
    var visualContext: String?
    var objectIntelligence: ObjectIntelligenceCard? = nil   // AI: VLM/Gemini understanding (nil until enriched)
//    var faceStyle: FaceVisualStyle?
}

struct ObjectSegmentation: @unchecked Sendable {
    var boundingBox: CGRect
    var centroid: CGPoint
    var areaFraction: Float
    var selectedInstanceIndex: Int
    var instanceCount: Int
    var maskPreviewImage: UIImage?
}
//
//struct FaceVisualStyle: @unchecked Sendable {
//    var eyeRimColor: UIColor
//    var eyeColor: UIColor
//    var pupilColor: UIColor
//    var browColor: UIColor
//    var mouthColor: UIColor
//    var objectColorDescription: String?
//    var objectBrightness: CGFloat?
//
//    static let standard = FaceVisualStyle(
//        eyeRimColor: UIColor(red: 0.16, green: 0.10, blue: 0.24, alpha: 1),
//        eyeColor: .white,
//        pupilColor: .black,
//        browColor: UIColor(red: 0.12, green: 0.09, blue: 0.07, alpha: 1),
//        mouthColor: UIColor(red: 0.08, green: 0.04, blue: 0.04, alpha: 1),
//        objectColorDescription: nil,
//        objectBrightness: nil
//    )
//
//    static func contrastingForObject(colorDescription: String?, brightness: CGFloat?) -> FaceVisualStyle {
//        guard let brightness, brightness < 0.42 else {
//            var style = standard
//            style.objectColorDescription = colorDescription
//            style.objectBrightness = brightness
//            return style
//        }
//
//        return FaceVisualStyle(
//            eyeRimColor: UIColor(red: 1.0, green: 0.95, blue: 0.70, alpha: 1),
//            eyeColor: .white,
//            pupilColor: UIColor(red: 0.04, green: 0.03, blue: 0.06, alpha: 1),
//            browColor: UIColor(red: 1.0, green: 0.89, blue: 0.45, alpha: 1),
//            mouthColor: UIColor(red: 1.0, green: 0.45, blue: 0.55, alpha: 1),
//            objectColorDescription: colorDescription,
//            objectBrightness: brightness
//        )
//    }
//}
//
//enum Emotion: String, Codable, CaseIterable {
//    case neutral
//    case happy
//    case curious
//    case surprised
//    case thinking
//    case confused
//    case excited
//
//    var displayName: String {
//        rawValue.capitalized
//    }
//}
//
//enum MouthShape: String, Codable {
//    case closed
//    case smallOpen
//    case open
//    case wideOpen
//    case smile
//    case oShape
//}
//
//enum MouthAnimationMode: String, Codable {
//    case idle
//    case talkingLoop
//    case thinking
//    case surprised
//}
//
//struct VoiceProfile: Codable, Equatable {
//    var voiceIdentifier: String?
//    var rate: Float
//    var pitch: Float
//    var volume: Float
//
//    static let cheerful = VoiceProfile(voiceIdentifier: nil, rate: 0.42, pitch: 1.08, volume: 1.0)
//    static let thoughtful = VoiceProfile(voiceIdentifier: nil, rate: 0.38, pitch: 1.0, volume: 1.0)
//    static let excited = VoiceProfile(voiceIdentifier: nil, rate: 0.45, pitch: 1.12, volume: 1.0)
//}
//
//struct ObjectPersona: Identifiable, Codable {
//    let id: UUID
//    var name: String
//    var objectLabel: String
//    var personality: String
//    var voiceProfile: VoiceProfile
//    var emotionStyle: Emotion
//    var greeting: String
//    var kidFriendlyFacts: [String]
//    var visualContext: String?
//
//    init(
//        id: UUID = UUID(),
//        name: String,
//        objectLabel: String,
//        personality: String,
//        voiceProfile: VoiceProfile,
//        emotionStyle: Emotion,
//        greeting: String,
//        kidFriendlyFacts: [String],
//        visualContext: String? = nil
//    ) {
//        self.id = id
//        self.name = name
//        self.objectLabel = objectLabel
//        self.personality = personality
//        self.voiceProfile = voiceProfile
//        self.emotionStyle = emotionStyle
//        self.greeting = greeting
//        self.kidFriendlyFacts = kidFriendlyFacts
//        self.visualContext = visualContext
//    }
//
//    enum CodingKeys: String, CodingKey {
//        case name
//        case objectLabel
//        case personality
//        case voiceProfile
//        case emotionStyle
//        case greeting
//        case kidFriendlyFacts
//        case visualContext
//    }
//
//    init(from decoder: Decoder) throws {
//        let container = try decoder.container(keyedBy: CodingKeys.self)
//        id = UUID()
//        name = try container.decode(String.self, forKey: .name)
//        objectLabel = try container.decode(String.self, forKey: .objectLabel)
//        personality = try container.decode(String.self, forKey: .personality)
//        voiceProfile = try container.decode(VoiceProfile.self, forKey: .voiceProfile)
//        emotionStyle = try container.decode(Emotion.self, forKey: .emotionStyle)
//        greeting = try container.decode(String.self, forKey: .greeting)
//        kidFriendlyFacts = try container.decode([String].self, forKey: .kidFriendlyFacts)
//        visualContext = try container.decodeIfPresent(String.self, forKey: .visualContext)
//    }
//
//    func encode(to encoder: Encoder) throws {
//        var container = encoder.container(keyedBy: CodingKeys.self)
//        try container.encode(name, forKey: .name)
//        try container.encode(objectLabel, forKey: .objectLabel)
//        try container.encode(personality, forKey: .personality)
//        try container.encode(voiceProfile, forKey: .voiceProfile)
//        try container.encode(emotionStyle, forKey: .emotionStyle)
//        try container.encode(greeting, forKey: .greeting)
//        try container.encode(kidFriendlyFacts, forKey: .kidFriendlyFacts)
//        try container.encodeIfPresent(visualContext, forKey: .visualContext)
//    }
//}
//
//struct ChatResponse: Codable {
//    var text: String
//    var emotion: Emotion
//    var voiceDirection: String
//    var rate: Float
//    var pitch: Float
//    var volume: Float
//    var mouthAnimationMode: MouthAnimationMode
//
//    var voiceProfile: VoiceProfile {
//        VoiceProfile(
//            voiceIdentifier: nil,
//            rate: rate,
//            pitch: pitch,
//            volume: volume
//        )
//    }
//
//    init(
//        text: String,
//        emotion: Emotion,
//        voiceDirection: String = "cheerful, gentle, playful",
//        rate: Float = 0.42,
//        pitch: Float = 1.08,
//        volume: Float = 1.0,
//        mouthAnimationMode: MouthAnimationMode
//    ) {
//        self.text = text
//        self.emotion = emotion
//        self.voiceDirection = voiceDirection
//        self.rate = rate
//        self.pitch = pitch
//        self.volume = volume
//        self.mouthAnimationMode = mouthAnimationMode
//    }
//
//    enum CodingKeys: String, CodingKey {
//        case text
//        case emotion
//        case voiceDirection
//        case rate
//        case pitch
//        case volume
//        case mouthAnimationMode
//    }
//
//    init(from decoder: Decoder) throws {
//        let container = try decoder.container(keyedBy: CodingKeys.self)
//        text = try container.decode(String.self, forKey: .text)
//        emotion = try container.decode(Emotion.self, forKey: .emotion)
//        voiceDirection = try container.decodeIfPresent(String.self, forKey: .voiceDirection) ?? "cheerful, gentle, playful"
//        rate = try container.decodeIfPresent(Float.self, forKey: .rate) ?? 0.42
//        pitch = try container.decodeIfPresent(Float.self, forKey: .pitch) ?? 1.08
//        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
//        mouthAnimationMode = try container.decodeIfPresent(MouthAnimationMode.self, forKey: .mouthAnimationMode) ?? .talkingLoop
//    }
//}
//
//struct ChatMessage: Identifiable, Equatable {
//    enum Role {
//        case child
//        case object
//    }
//
//    let id = UUID()
//    var role: Role
//    var text: String
//    var emotion: Emotion?
//    var createdAt = Date()
//}

//import CoreGraphics
//import CoreVideo
//import Foundation
//import UIKit

/// Teaching sample for using Kida's SAM segmenter.
///
/// This file is not part of the app target by default. It shows the minimum flow:
/// camera frame + tap point -> SAM mask -> centroid/bounding box -> screen anchor.
///
/// Required model files in the app bundle:
/// - SAM2_1SmallImageEncoderFLOAT16.mlpackage
/// - SAM2_1SmallPromptEncoderFLOAT16.mlpackage
/// - SAM2_1SmallMaskDecoderFLOAT16.mlpackage
//final class SAMUsageExample {
//    private let segmenter: ObjectSegmenting
//
//    init(segmenter: ObjectSegmenting = SAM2ObjectSegmenter()) {
//        self.segmenter = segmenter
//    }
//
//    /// Call this once before the first scan, for example when the camera screen opens.
//    func warmUpSAM() async {
//        await segmenter.prepare()
//    }
//
//    /// Segment the object the user tapped.
//    ///
//    /// - Parameters:
//    ///   - pixelBuffer: Camera image. In Kida this usually comes from `ARFrame.capturedImage`.
//    ///   - tapInView: The place the child tapped in screen/view coordinates.
//    ///   - viewSize: The size of the AR/camera view that received the tap.
//    ///   - includePreview: Use `true` for debugging UI, `false` for fastest production scans.
//    func segmentTappedObject(
//        pixelBuffer: CVPixelBuffer,
//        tapInView: CGPoint,
//        viewSize: CGSize,
//        includePreview: Bool = true
//    ) async -> SAMExampleResult? {
//        let normalizedTap = SAMAnchorMath.normalizedTargetPoint(
//            tapInView: tapInView,
//            viewSize: viewSize
//        )
//
//        guard let segmentation = await segmenter.segment(
//            pixelBuffer: PixelBufferReference(value: pixelBuffer),
//            targetPoint: normalizedTap,
//            includePreview: includePreview
//        ) else {
//            return nil
//        }
//
//        return SAMExampleResult(
//            boundingBox: segmentation.boundingBox,
//            centroid: segmentation.centroid,
//            screenAnchorPoint: SAMAnchorMath.screenPoint(
//                fromNormalizedPoint: segmentation.centroid,
//                viewSize: viewSize
//            ),
//            screenBoundingBox: SAMAnchorMath.screenRect(
//                fromNormalizedBoundingBox: segmentation.boundingBox,
//                viewSize: viewSize
//            ),
//            areaFraction: segmentation.areaFraction,
//            maskPreviewImage: segmentation.maskPreviewImage
//        )
//    }
//}
//
//struct SAMExampleResult {
//    /// Normalized CGRect from SAM, values are 0...1.
//    /// Kida stores this using Vision-style coordinates: origin is bottom-left.
//    let boundingBox: CGRect
//
//    /// Normalized CGPoint from SAM, values are 0...1.
//    /// `centroid.x` and `centroid.y` are already CGFloat.
//    let centroid: CGPoint
//
//    /// Use this 2D point for UI overlays, or pass it into an AR raycast.
//    let screenAnchorPoint: CGPoint
//
//    /// Same box converted into UIKit screen coordinates.
//    let screenBoundingBox: CGRect
//
//    /// Approximate size of the selected mask compared with the full image.
//    let areaFraction: Float
//
//    /// Debug image. Useful for showing the selected object mask on screen.
//    let maskPreviewImage: UIImage?
//}

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
