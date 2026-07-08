import Foundation
import UIKit

protocol VisualUnderstandingProviding: Sendable {
    var isAvailable: Bool { get }

    func makeObjectUnderstanding(for detectedObject: DetectedObject) async throws -> ObjectUnderstandingResult
}

struct ObjectUnderstandingResult: Sendable {
    var objectIntelligence: ObjectIntelligenceCard
    var retrievedFacts: RetrievedObjectFacts?
    var suggestedQuestions: [String]
    var source: String?

    init(
        objectIntelligence: ObjectIntelligenceCard,
        retrievedFacts: RetrievedObjectFacts? = nil,
        suggestedQuestions: [String] = [],
        source: String? = nil
    ) {
        self.objectIntelligence = objectIntelligence
        self.retrievedFacts = retrievedFacts
        self.suggestedQuestions = suggestedQuestions
        self.source = source
    }
}

struct CascadingVisualUnderstandingProvider: VisualUnderstandingProviding {
    private let providers: [any VisualUnderstandingProviding]

    // Order = preference. Mac VLM leads in dev (when VLM_SERVER_URL is set on the LAN);
    // Gemini is the reachable-everywhere cloud fallback for TestFlight/Release builds where
    // no Mac server is present. Each is gated by isAvailable, so absent config is skipped.
    init(providers: [any VisualUnderstandingProviding] = [
        MacVLMVisualUnderstandingProvider(),
        GeminiVisualUnderstandingProvider()
    ]) {
        self.providers = providers
    }

    var isAvailable: Bool {
        providers.contains { $0.isAvailable }
    }

    func makeObjectUnderstanding(for detectedObject: DetectedObject) async throws -> ObjectUnderstandingResult {
        var lastError: Error?

        for provider in providers where provider.isAvailable {
            do {
                return try await provider.makeObjectUnderstanding(for: detectedObject)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? VisualUnderstandingProviderError.noAvailableProvider
    }
}

enum VisualUnderstandingProviderError: LocalizedError {
    case noAvailableProvider

    var errorDescription: String? {
        switch self {
        case .noAvailableProvider:
            return "No visual understanding provider is configured."
        }
    }
}

struct MacVLMVisualUnderstandingProvider: VisualUnderstandingProviding {
    var isAvailable: Bool {
        configuration != nil
    }

    private let configuration: MacVLMConfiguration?

    init(configuration: MacVLMConfiguration? = MacVLMConfiguration.load()) {
        self.configuration = configuration
    }

    func makeObjectUnderstanding(for detectedObject: DetectedObject) async throws -> ObjectUnderstandingResult {
        guard let configuration else {
            throw MacVLMVisualUnderstandingError.missingConfiguration
        }

        guard let imageData = ObjectFrameJPEGData.make(from: detectedObject) else {
            throw MacVLMVisualUnderstandingError.missingImage
        }

        let url = configuration.baseURL.appendingPathComponent("object/understand")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning") // free-ngrok: get JSON, not the warning page

        if let token = configuration.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(
            MacVLMObjectUnderstandingRequest(
                image: MacVLMImagePayload(
                    mimeType: "image/jpeg",
                    data: imageData.base64EncodedString()
                ),
                detector: MacVLMDetectorHint(
                    label: detectedObject.label,
                    confidence: detectedObject.confidence,
                    alternatives: detectedObject.alternatives,
                    visualContext: detectedObject.visualContext,
                    focusRegion: VLMFocusRegion.make(from: detectedObject)
                )
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MacVLMVisualUnderstandingError.badStatus(-1, "No HTTP response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No error body."
            throw MacVLMVisualUnderstandingError.badStatus(httpResponse.statusCode, message)
        }

        let serverResponse = try JSONDecoder().decode(MacVLMObjectUnderstandingResponse.self, from: data)
        return ObjectUnderstandingResult(
            objectIntelligence: serverResponse.objectIntelligence,
            retrievedFacts: serverResponse.retrievedFacts,
            suggestedQuestions: serverResponse.suggestedQuestions ?? [],
            source: serverResponse.source
        )
    }
}

struct MacVLMConfiguration: Sendable {
    var baseURL: URL
    var token: String?
    var timeout: TimeInterval

    static func load() -> MacVLMConfiguration? {
        let info = Bundle.main.infoDictionary ?? [:]
        let urlString = (info["VLMServerURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = (info["VLMServerToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let timeoutString = (info["VLMServerTimeout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !urlString.isEmpty,
              !urlString.contains("$("),
              let url = URL(string: urlString),
              url.host?.isEmpty == false else {
            return nil
        }

        return MacVLMConfiguration(
            baseURL: url,
            token: token.isEmpty || token.contains("$(") ? nil : token,
            // Cold VLM calls (and Tier-1 Qwen enrichment) routinely exceed 5s;
            // 5s spuriously failed every cold request. See architecture review P0 #2.
            timeout: TimeInterval(timeoutString) ?? 15
        )
    }
}

enum MacVLMVisualUnderstandingError: LocalizedError {
    case missingConfiguration
    case missingImage
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Mac VLM server is not configured."
        case .missingImage:
            return "No object image is available for the Mac VLM server."
        case let .badStatus(statusCode, message):
            return "Mac VLM server returned \(statusCode): \(message)"
        }
    }
}

struct GeminiVisualUnderstandingProvider: VisualUnderstandingProviding {
    var isAvailable: Bool {
        configuration != nil
    }

    private let configuration: GeminiConfiguration?

    init(configuration: GeminiConfiguration? = GeminiConfiguration.load()) {
        self.configuration = configuration
    }

    func makeObjectUnderstanding(for detectedObject: DetectedObject) async throws -> ObjectUnderstandingResult {
        guard let configuration else {
            throw GeminiVisualUnderstandingError.missingConfiguration
        }

        guard let imageData = ObjectFrameJPEGData.make(from: detectedObject) else {
            throw GeminiVisualUnderstandingError.missingImage
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "generativelanguage.googleapis.com"
        components.path = "/v1beta/models/\(configuration.modelID):generateContent"
        components.queryItems = [
            URLQueryItem(name: "key", value: configuration.apiKey)
        ]

        guard let url = components.url else {
            throw GeminiVisualUnderstandingError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GeminiGenerateContentRequest(
                contents: [
                    GeminiContent(
                        parts: [
                            GeminiPart(text: Self.prompt(for: detectedObject)),
                            GeminiPart(
                                inlineData: GeminiInlineData(
                                    mimeType: "image/jpeg",
                                    data: imageData.base64EncodedString()
                                )
                            )
                        ]
                    )
                ],
                generationConfig: GeminiGenerationConfig(
                    temperature: 0.15,
                    responseMimeType: "application/json"
                )
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiVisualUnderstandingError.badStatus(-1, "No HTTP response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No error body."
            throw GeminiVisualUnderstandingError.badStatus(httpResponse.statusCode, message)
        }

        let text = try Self.outputText(from: data)
        let json = Self.extractJSONObject(from: text)
        let card = try JSONDecoder().decode(ObjectIntelligenceCard.self, from: Data(json.utf8))
        return ObjectUnderstandingResult(objectIntelligence: card, source: "gemini")
    }

    private static func prompt(for detectedObject: DetectedObject) -> String {
        let alternatives = detectedObject.alternatives.isEmpty
            ? "none"
            : detectedObject.alternatives.joined(separator: ", ")
        let confidence = Int((detectedObject.confidence * 100).rounded())

        return """
        Analyze the whole camera image, but focus on the object inside the target area.
        The target area is \(VLMFocusRegion.make(from: detectedObject).promptDescription).
        Treat other visible things as background unless they help identify the target object.

        Detector hint:
        - label: \(detectedObject.label)
        - confidence: \(confidence)%
        - alternatives: \(alternatives)

        Return JSON only with exactly these keys:
        {
          "primaryLabel": "common object noun, lowercase",
          "confidence": 0.0,
          "visualSummary": "one short factual visual description",
          "colors": ["visible color names"],
          "material": "likely material or null",
          "shape": "simple shape description or null",
          "readableText": ["short visible words or letters"],
          "likelyUses": ["safe everyday use"],
          "safetyNotes": ["child-safety caveat if relevant"],
          "uncertainty": "low, medium, or high",
          "personality": "one of: boss, cool, fancy, sweet, cautious",
          "emotion": "one of: neutral, happy, curious, surprised, thinking, excited"
        }

        Use simple object labels such as bottle, cup, book, plant, toy, chair, table, bag, phone, laptop, pen, or object.
        Do not guess brand names. Do not identify people. Do not claim invisible details.
        For confidence, use 0.0 to 1.0.
        Choose personality by what the object is:
        - boss: money, keys, remote, book, calculator, phone, laptop (status / control)
        - cool: ball, skateboard, headphones, sneakers, bike (sport / play / style)
        - fancy: perfume, jewelry, trophy, wine glass, vase (formal / elegant / special)
        - sweet: plush toy, pillow, blanket, teapot, flower (soft / comfort / care)
        - cautious: anything sharp, hot, electrical, or medicine (dangerous — needs an adult)
        Choose emotion as the friendly mood that suits the object.
        Keep arrays short: at most 4 items each.
        """
    }

    private static func outputText(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        guard let text = response.candidates.first?.content.parts.compactMap(\.text).joined(separator: "\n"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiVisualUnderstandingError.emptyResponse
        }

        return text
    }

    private static func extractJSONObject(from output: String) -> String {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}") else {
            return output
        }

        return String(output[start...end])
    }
}

private enum ObjectFrameJPEGData {
    static func make(
        from detectedObject: DetectedObject,
        maxDimension: CGFloat = 1024,
        compressionQuality: CGFloat = 0.76
    ) -> Data? {
        guard let image = detectedObject.capturedImage else {
            return nil
        }

        let normalizedImage = normalized(image)
        let resizedImage = resized(normalizedImage, maxDimension: maxDimension)
        return resizedImage.jpegData(compressionQuality: compressionQuality)
    }

    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else {
            return image
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let currentMaxDimension = max(image.size.width, image.size.height)
        guard currentMaxDimension > maxDimension else {
            return image
        }

        let scale = maxDimension / currentMaxDimension
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

struct GeminiConfiguration: Sendable {
    var apiKey: String
    var modelID: String

    static func load() -> GeminiConfiguration? {
        let info = Bundle.main.infoDictionary ?? [:]
        let apiKey = (info["GeminiAPIKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelID = (info["GeminiModelID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !apiKey.isEmpty,
              !apiKey.contains("$(") else {
            return nil
        }

        return GeminiConfiguration(
            apiKey: apiKey,
            // Pinned to gemini-2.5-flash (still GA 2026-07; 2.0 Flash was retired 2026-06).
            // Override via GEMINI_MODEL_ID in Secrets.xcconfig.
            modelID: modelID.isEmpty || modelID.contains("$(") ? "gemini-2.5-flash" : modelID
        )
    }
}

enum GeminiVisualUnderstandingError: LocalizedError {
    case missingConfiguration
    case missingImage
    case invalidURL
    case badStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Gemini API key is not configured."
        case .missingImage:
            return "No object image is available for Gemini."
        case .invalidURL:
            return "Gemini URL could not be created."
        case let .badStatus(statusCode, message):
            return "Gemini returned \(statusCode): \(message)"
        case .emptyResponse:
            return "Gemini returned no object description."
        }
    }
}

struct ObjectFactStore: Sendable {
    private let entries: [ObjectFactEntry] = [
        ObjectFactEntry(
            label: "bottle",
            aliases: ["water bottle", "flask", "container"],
            facts: [
                "Bottles hold liquids so people can carry drinks.",
                "A cap or lid helps stop spills.",
                "Bottles can be made from plastic, glass, or metal.",
                "Reusable bottles can reduce trash."
            ],
            safetyNotes: [
                "Do not suggest drinking unknown liquids.",
                "Suggest asking an adult before opening sealed containers."
            ]
        ),
        ObjectFactEntry(
            label: "cup",
            aliases: ["mug", "teacup", "glass"],
            facts: [
                "Cups hold drinks and make sipping easier.",
                "A handle can protect fingers from warm drinks.",
                "Wide cups are easier to tip than bottles.",
                "Cups can be ceramic, plastic, glass, paper, or metal."
            ],
            safetyNotes: [
                "Do not suggest touching hot drinks.",
                "Mention adult help for broken glass or sharp ceramic pieces."
            ]
        ),
        ObjectFactEntry(
            label: "book",
            aliases: ["notebook", "binder", "comic book"],
            facts: [
                "Books store stories, pictures, and ideas on pages.",
                "Pages are usually read in order so the idea can grow step by step.",
                "A cover helps protect pages.",
                "Books can teach facts or tell imaginary stories."
            ],
            safetyNotes: [
                "Encourage gentle page turning instead of tearing pages."
            ]
        ),
        ObjectFactEntry(
            label: "plant",
            aliases: ["potted plant", "houseplant", "flower"],
            facts: [
                "Many plants use sunlight to make food.",
                "Roots help plants drink water from soil.",
                "Leaves help plants breathe and catch light.",
                "Plants grow slowly with light, water, air, and care."
            ],
            safetyNotes: [
                "Do not suggest eating leaves or berries.",
                "Suggest asking an adult before watering or touching unknown plants."
            ]
        ),
        ObjectFactEntry(
            label: "chair",
            aliases: ["seat", "stool"],
            facts: [
                "Chairs support people while they sit.",
                "Chair legs spread weight down to the floor.",
                "A backrest helps people lean and rest.",
                "Some chairs roll, fold, spin, or rock."
            ],
            safetyNotes: [
                "Do not suggest climbing or standing on chairs."
            ]
        ),
        ObjectFactEntry(
            label: "toy",
            aliases: ["doll", "figurine", "plush", "teddy"],
            facts: [
                "Toys help kids imagine, practice, and tell stories.",
                "Different toy shapes can teach colors, balance, and movement.",
                "Soft toys are often made with fabric and stuffing.",
                "Building toys can help people learn patterns."
            ],
            safetyNotes: [
                "Mention adult help if a toy has tiny parts or batteries."
            ]
        ),
        ObjectFactEntry(
            label: "bag",
            aliases: ["backpack", "handbag", "purse"],
            facts: [
                "Bags carry objects from one place to another.",
                "Straps help spread weight across hands, shoulders, or backs.",
                "Pockets keep small items easier to find.",
                "Bags can be made from fabric, leather, paper, or plastic."
            ],
            safetyNotes: [
                "Do not suggest looking inside someone else's bag without permission."
            ]
        ),
        ObjectFactEntry(
            label: "phone",
            aliases: ["smartphone", "mobile phone"],
            facts: [
                "Phones can send messages, make calls, and show pictures.",
                "A touchscreen senses taps from fingers.",
                "Phones use batteries, tiny chips, speakers, cameras, and antennas.",
                "Apps are small programs that help a phone do jobs."
            ],
            safetyNotes: [
                "Remind children to ask an adult before calling, sharing photos, or opening apps."
            ]
        ),
        ObjectFactEntry(
            label: "laptop",
            aliases: ["computer", "notebook computer"],
            facts: [
                "Laptops are portable computers with screens and keyboards.",
                "Computers follow instructions called programs.",
                "A keyboard helps people write letters and commands.",
                "Laptops use batteries so they can work away from a wall plug."
            ],
            safetyNotes: [
                "Suggest adult help before changing settings or sharing information online."
            ]
        ),
        ObjectFactEntry(
            label: "pen",
            aliases: ["pencil", "marker"],
            facts: [
                "Pens and pencils make marks so people can write or draw.",
                "Ink pens use liquid color that flows to a tiny tip.",
                "Pencils use graphite, which can be erased from paper.",
                "Markers often make wider, brighter lines."
            ],
            safetyNotes: [
                "Do not suggest drawing on skin, walls, screens, or furniture."
            ]
        ),
        ObjectFactEntry(
            label: "table",
            aliases: ["desk"],
            facts: [
                "Tables hold objects at a useful height.",
                "A flat top gives people a place to work, eat, draw, or build.",
                "Table legs carry weight down to the floor.",
                "Desks are tables often used for reading, writing, or computers."
            ],
            safetyNotes: [
                "Do not suggest climbing or sitting on tables."
            ]
        )
    ]

    func retrieve(
        for persona: ObjectPersona,
        question: String,
        limit: Int = 4
    ) -> RetrievedObjectFacts {
        let labelCandidates = [
            persona.objectIntelligence?.primaryLabel,
            persona.objectLabel
        ].compactMap { $0 }.map(ObjectLabelNormalizer.normalize)

        return retrieve(labelCandidates: labelCandidates, question: question, limit: limit)
    }

    func retrieve(
        for detectedObject: DetectedObject,
        question: String? = nil,
        limit: Int = 4
    ) -> RetrievedObjectFacts {
        let labelCandidates = [
            detectedObject.objectIntelligence?.primaryLabel,
            detectedObject.label
        ].compactMap { $0 }.map(ObjectLabelNormalizer.normalize) + detectedObject.alternatives.map(ObjectLabelNormalizer.normalize)

        return retrieve(labelCandidates: labelCandidates, question: question ?? "", limit: limit)
    }

    private func retrieve(
        labelCandidates: [String],
        question: String,
        limit: Int
    ) -> RetrievedObjectFacts {
        let selectedEntry = entries
            .map { entry in
                (entry: entry, score: entry.score(for: labelCandidates))
            }
            .sorted { lhs, rhs in lhs.score > rhs.score }
            .first { $0.score > 0 }?
            .entry

        guard let selectedEntry else {
            return RetrievedObjectFacts(
                label: labelCandidates.first ?? "object",
                facts: [
                    "Every object has a shape, a material, and a job.",
                    "Looking closely can reveal color, texture, parts, and clues."
                ],
                safetyNotes: [
                    "Avoid telling a child to taste, open, climb, or use unknown objects without an adult."
                ]
            )
        }

        return RetrievedObjectFacts(
            label: selectedEntry.label,
            facts: selectedEntry.rankedFacts(for: question, limit: limit),
            safetyNotes: selectedEntry.safetyNotes
        )
    }
}

struct RetrievedObjectFacts: Codable, Equatable, Sendable {
    var label: String
    var facts: [String]
    var safetyNotes: [String]

    var promptContext: String {
        var lines = [
            "Local object facts for \(label):"
        ]
        lines.append(contentsOf: facts.map { "- \($0)" })

        if !safetyNotes.isEmpty {
            lines.append("Safety notes:")
            lines.append(contentsOf: safetyNotes.map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
    }
}

private struct ObjectFactEntry: Sendable {
    var label: String
    var aliases: [String]
    var facts: [String]
    var safetyNotes: [String]

    func score(for labelCandidates: [String]) -> Int {
        let terms = Set(([label] + aliases).map(ObjectLabelNormalizer.normalize))
        return labelCandidates.reduce(0) { score, candidate in
            terms.contains(candidate) || terms.contains(where: { candidate.contains($0) || $0.contains(candidate) })
                ? score + 4
                : score
        }
    }

    func rankedFacts(for question: String, limit: Int) -> [String] {
        let queryTokens = Set(Self.tokens(in: question))
        guard !queryTokens.isEmpty else {
            return Array(facts.prefix(limit))
        }

        let ranked = facts
            .enumerated()
            .map { index, fact in
                let overlap = Set(Self.tokens(in: fact)).intersection(queryTokens).count
                return (fact: fact, score: overlap, index: index)
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.index < $1.index
                }

                return $0.score > $1.score
            }

        return Array(ranked.prefix(limit).map(\.fact))
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
    }
}

private struct GeminiGenerateContentRequest: Encodable {
    var contents: [GeminiContent]
    var generationConfig: GeminiGenerationConfig
}

private struct MacVLMObjectUnderstandingRequest: Encodable {
    var image: MacVLMImagePayload
    var detector: MacVLMDetectorHint
}

private struct MacVLMImagePayload: Encodable {
    var mimeType: String
    var data: String
}

private struct MacVLMDetectorHint: Encodable {
    var label: String
    var confidence: Float
    var alternatives: [String]
    var visualContext: String?
    var focusRegion: VLMFocusRegion
}

private struct VLMFocusRegion: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var description: String

    var promptDescription: String {
        "\(description): normalized box x=\(Self.format(x)), y=\(Self.format(y)), width=\(Self.format(width)), height=\(Self.format(height)); origin is bottom-left."
    }

    static func make(from detectedObject: DetectedObject) -> VLMFocusRegion {
        let sourceBox = detectedObject.segmentation?.boundingBox ?? detectedObject.boundingBox
        let box = sourceBox.map { clamped($0) } ?? CGRect(x: 0.32, y: 0.40, width: 0.36, height: 0.36)
        return VLMFocusRegion(
            x: Double(box.minX),
            y: Double(box.minY),
            width: Double(box.width),
            height: Double(box.height),
            description: sourceBox == nil
                ? "the center target box where the child framed the object"
                : "the detected target object box"
        )
    }

    private static func clamped(_ rect: CGRect) -> CGRect {
        let box = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, !box.isEmpty else {
            return CGRect(x: 0.32, y: 0.40, width: 0.36, height: 0.36)
        }
        return box
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private struct MacVLMObjectUnderstandingResponse: Decodable {
    var objectIntelligence: ObjectIntelligenceCard
    var retrievedFacts: RetrievedObjectFacts?
    var suggestedQuestions: [String]?
    var source: String?
}

private struct GeminiContent: Encodable {
    var parts: [GeminiPart]
}

private struct GeminiPart: Encodable {
    var text: String?
    var inlineData: GeminiInlineData?

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }

    init(text: String) {
        self.text = text
        inlineData = nil
    }

    init(inlineData: GeminiInlineData) {
        text = nil
        self.inlineData = inlineData
    }
}

private struct GeminiInlineData: Encodable {
    var mimeType: String
    var data: String

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }
}

private struct GeminiGenerationConfig: Encodable {
    var temperature: Double
    var responseMimeType: String
}

private struct GeminiGenerateContentResponse: Decodable {
    var candidates: [GeminiCandidate]
}

private struct GeminiCandidate: Decodable {
    var content: GeminiResponseContent
}

private struct GeminiResponseContent: Decodable {
    var parts: [GeminiResponsePart]
}

private struct GeminiResponsePart: Decodable {
    var text: String?
}
