import Combine
import Foundation

@MainActor
final class KidaViewModel: ObservableObject {
    @Published var statusMessage = "Point at an object, tap it, then scan."
    @Published var detectedObject: DetectedObject?
    @Published var persona: ObjectPersona?
    @Published var messages: [ChatMessage] = []
    @Published var inputText = ""
    @Published var isScanning = false
    @Published var isSpeaking = false
    @Published var isListening = false
    @Published var isFacePlaced = false
    @Published var isSegmentingTarget = false
    @Published var savedCount = 0
    @Published var savedPersonas: [ObjectPersona] = []

    let suggestedQuestions = [
        "What are you?",
        "What do you do?",
        "Tell me a fun fact"
    ]

    private let detector: ObjectDetecting
    private let personaGenerator: PersonaGenerating
    private let speechService: SpeechSynthesizerService
    private let speechRecognitionService: SpeechRecognitionService
    private let libraryStore: PersonaLibraryStore
    private let imageContextExtractor: ImageContextExtractor
    private let segmenter: ObjectSegmenting
    private let faceStyler: ObjectFaceStyler
    private var arController: ARFacePlacementController?
    private var targetSegmentationTask: Task<Void, Never>?
    private var segmenterWarmUpTask: Task<Void, Never>?
    private var targetSegmentationSequence = 0
    private var selectedSegmentationDate: Date?
    private let selectedSegmentationMaxAge: TimeInterval = 8.0
    private let targetSegmentationDebounceNanoseconds: UInt64 = 180_000_000

    init(
        detector: ObjectDetecting = VisionObjectDetector(),
        personaGenerator: PersonaGenerating = FoundationPersonaGenerator(),
        speechService: SpeechSynthesizerService = SpeechSynthesizerService(),
        speechRecognitionService: SpeechRecognitionService = SpeechRecognitionService(),
        libraryStore: PersonaLibraryStore = PersonaLibraryStore(),
        imageContextExtractor: ImageContextExtractor = ImageContextExtractor(),
        segmenter: ObjectSegmenting = HybridObjectSegmenter(),
        faceStyler: ObjectFaceStyler = ObjectFaceStyler()
    ) {
        self.detector = detector
        self.personaGenerator = personaGenerator
        self.speechService = speechService
        self.speechRecognitionService = speechRecognitionService
        self.libraryStore = libraryStore
        self.imageContextExtractor = imageContextExtractor
        self.segmenter = segmenter
        self.faceStyler = faceStyler
        savedPersonas = libraryStore.load()
        savedCount = savedPersonas.count
    }

    func attachARController(_ controller: ARFacePlacementController) {
        arController = controller
        prewarmSegmenter()
    }

    func targetPointDidChange() {
        isFacePlaced = false
        previewTargetSegmentation()
    }

    func scanCurrentObject() {
        guard !isScanning else {
            return
        }

        targetSegmentationTask?.cancel()
        targetSegmentationTask = nil
        targetSegmentationSequence += 1
        isSegmentingTarget = false

        Task(priority: .userInitiated) {
            await runScan()
        }
    }

    func sendCurrentMessage() {
        if isListening {
            stopVoiceInput(sendFinalTranscript: false)
        }

        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        inputText = ""
        send(message: trimmed)
    }

    func sendSuggestedQuestion(_ question: String) {
        send(message: question)
    }

    func toggleVoiceInput() {
        if isListening {
            stopVoiceInput(sendFinalTranscript: true)
        } else {
            startVoiceInput()
        }
    }

    func saveCurrentPersona() {
        guard let persona else {
            statusMessage = "Scan an object before saving."
            return
        }

        libraryStore.save(persona)
        savedPersonas = libraryStore.load()
        savedCount = savedPersonas.count
        statusMessage = "\(persona.name) was saved to the library."
    }

    private func runScan() async {
        guard let pixelBuffer = arController?.currentPixelBuffer() else {
            statusMessage = "Camera is not ready yet. Move slowly and try again."
            return
        }

        isScanning = true
        isFacePlaced = false
        statusMessage = "Looking closely..."

        let pixelBufferReference = PixelBufferReference(value: pixelBuffer)
        let targetPoint = arController?.currentTargetPointNormalized()
        let cachedSegmentation = freshSelectedSegmentation()
        async let detectedTask = detector.detect(pixelBuffer: pixelBufferReference)
        let segmentation = if let cachedSegmentation {
            cachedSegmentation
        } else {
            await segmenter.segment(
                pixelBuffer: pixelBufferReference,
                targetPoint: targetPoint,
                includePreview: false
            )
        }

        var enrichedDetected = await detectedTask
        if let segmentation {
            enrichedDetected.segmentation = segmentation
            enrichedDetected.boundingBox = segmentation.boundingBox
        }
        enrichedDetected.faceStyle = faceStyler.style(for: enrichedDetected)
        enrichedDetected.visualContext = imageContextExtractor.makeFastContext(for: enrichedDetected)
        detectedObject = enrichedDetected
        statusMessage = detectionStatus(for: enrichedDetected)

        let placed = arController?.placeFace(
            near: enrichedDetected.boundingBox,
            objectPoint: enrichedDetected.segmentation?.centroid,
            initialEmotion: .curious,
            visualStyle: enrichedDetected.faceStyle ?? .standard
        ) ?? false
        if placed {
            isFacePlaced = true
            statusMessage = "Face placed. Creating a personality..."
        } else {
            statusMessage = "I found \(enrichedDetected.label), but AR placement needs another tap."
        }

        let generatedPersona = ObjectVoiceDirector.applyVoice(
            to: await personaGenerator.makePersona(for: enrichedDetected),
            for: enrichedDetected.label
        )
        persona = generatedPersona
        arController?.applyEmotion(generatedPersona.emotionStyle, animated: true)

        if placed {
            statusMessage = "Meet \(generatedPersona.name)."
        }

        let greeting = ChatResponse(
            text: generatedPersona.greeting,
            emotion: generatedPersona.emotionStyle,
            voiceDirection: "warm, cheerful, friendly greeting",
            rate: generatedPersona.voiceProfile.rate,
            pitch: generatedPersona.voiceProfile.pitch,
            volume: generatedPersona.voiceProfile.volume,
            mouthAnimationMode: .talkingLoop
        )

        messages = [
            ChatMessage(role: .object, text: greeting.text, emotion: greeting.emotion)
        ]
        speak(greeting, persona: generatedPersona)
        isScanning = false
    }

    private func previewTargetSegmentation() {
        targetSegmentationTask?.cancel()
        targetSegmentationSequence += 1
        selectedSegmentationDate = nil

        guard let pixelBuffer = arController?.currentPixelBuffer(),
              let targetPoint = arController?.currentTargetPointNormalized() else {
            statusMessage = "Target selected. Tap Scan to bring it to life."
            return
        }

        isSegmentingTarget = true
        statusMessage = "Target selected..."
        let requestID = targetSegmentationSequence
        let pixelBufferReference = PixelBufferReference(value: pixelBuffer)

        targetSegmentationTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: self.targetSegmentationDebounceNanoseconds)
            guard !Task.isCancelled,
                  requestID == self.targetSegmentationSequence else {
                return
            }

            self.statusMessage = "Segmenting selected object..."

            let segmentation = await self.segmenter.segment(
                pixelBuffer: pixelBufferReference,
                targetPoint: targetPoint,
                includePreview: true
            )

            guard !Task.isCancelled,
                  requestID == self.targetSegmentationSequence else {
                return
            }

            self.isSegmentingTarget = false

            guard let segmentation else {
                self.statusMessage = "I could not separate that object yet. Try tapping its center."
                return
            }

            var selectedObject = self.detectedObject ?? DetectedObject(
                label: "object",
                confidence: 0,
                capturedImage: nil,
                boundingBox: nil,
                segmentation: nil,
                alternatives: [],
                visualContext: nil,
                faceStyle: nil
            )
            selectedObject.segmentation = segmentation
            selectedObject.boundingBox = segmentation.boundingBox
            self.detectedObject = selectedObject
            self.selectedSegmentationDate = Date()
            self.statusMessage = "Object segmented. Tap Scan to bring it to life."
        }
    }

    private func prewarmSegmenter() {
        guard segmenterWarmUpTask == nil else {
            return
        }

        let segmenter = segmenter
        segmenterWarmUpTask = Task.detached(priority: .utility) {
            await segmenter.prepare()
        }
    }

    private func freshSelectedSegmentation() -> ObjectSegmentation? {
        guard let segmentation = detectedObject?.segmentation,
              let selectedSegmentationDate,
              Date().timeIntervalSince(selectedSegmentationDate) <= selectedSegmentationMaxAge else {
            return nil
        }

        var scanSegmentation = segmentation
        scanSegmentation.maskPreviewImage = nil
        return scanSegmentation
    }

    private func startVoiceInput() {
        speechService.stop()
        isListening = true
        inputText = ""
        statusMessage = "Listening..."

        speechRecognitionService.startListening(
            onTranscript: { [weak self] transcript in
                guard let self else {
                    return
                }

                inputText = transcript
                statusMessage = transcript.isEmpty ? "Listening..." : "Listening: \(transcript)"
            },
            onFinish: { [weak self] transcript in
                guard let self else {
                    return
                }

                isListening = false
                inputText = transcript

                if transcript.isEmpty {
                    statusMessage = "I did not hear a question. Try again."
                } else {
                    sendCurrentMessage()
                }
            },
            onError: { [weak self] message in
                guard let self else {
                    return
                }

                isListening = false
                statusMessage = message
            }
        )
    }

    private func stopVoiceInput(sendFinalTranscript: Bool) {
        isListening = false
        speechRecognitionService.stopListening(sendFinalTranscript: sendFinalTranscript)
        if !sendFinalTranscript {
            statusMessage = "Voice question cancelled."
        }
    }

    private func send(message: String) {
        let activePersona: ObjectPersona
        if let persona {
            activePersona = persona
        } else {
            let fallbackObject = DetectedObject(
                label: "object",
                confidence: 0,
                capturedImage: nil,
                boundingBox: nil,
                segmentation: nil,
                alternatives: [],
                visualContext: nil,
                faceStyle: nil
            )
            activePersona = ObjectVoiceDirector.applyVoice(
                to: LocalPersonaFactory().makePersona(for: fallbackObject),
                for: fallbackObject.label
            )
            persona = activePersona
        }

        messages.append(ChatMessage(role: .child, text: message, emotion: nil))

        Task {
            statusMessage = "\(activePersona.name) is thinking..."
            arController?.applyEmotion(.thinking, animated: true)
            let responsePersona = await personaWithDetailedVisualContextIfNeeded(
                for: message,
                persona: activePersona
            )

            let response = await personaGenerator.makeResponse(
                for: message,
                persona: responsePersona,
                history: messages
            )

            messages.append(ChatMessage(role: .object, text: response.text, emotion: response.emotion))
            statusMessage = "\(responsePersona.name) answered."
            speak(response, persona: responsePersona)
        }
    }

    private func personaWithDetailedVisualContextIfNeeded(
        for message: String,
        persona activePersona: ObjectPersona
    ) async -> ObjectPersona {
        guard shouldReadDetailedVisualContext(for: message),
              let currentDetectedObject = detectedObject else {
            return activePersona
        }

        statusMessage = "Checking the scan image..."
        let detailedContext = await imageContextExtractor.makeDetailedContext(for: currentDetectedObject)

        var updatedDetectedObject = currentDetectedObject
        updatedDetectedObject.visualContext = detailedContext
        detectedObject = updatedDetectedObject

        var updatedPersona = activePersona
        updatedPersona.visualContext = detailedContext
        if persona?.id == activePersona.id {
            persona = updatedPersona
        }

        return updatedPersona
    }

    private func speak(_ response: ChatResponse, persona: ObjectPersona) {
        arController?.applyEmotion(response.emotion, animated: true)

        speechService.speak(
            text: response.text,
            voiceProfile: voiceProfile(for: response, persona: persona),
            onStart: { [weak self] in
                Task { @MainActor in
                    self?.isSpeaking = true
                    self?.arController?.stopTalking(restingEmotion: response.emotion)
                }
            },
            onWord: { [weak self] word, _ in
                Task { @MainActor in
                    self?.arController?.speakWord(word, emotion: response.emotion)
                }
            },
            onFinish: { [weak self] in
                Task { @MainActor in
                    self?.isSpeaking = false
                    self?.arController?.stopTalking(restingEmotion: response.emotion)
                }
            },
            onError: { [weak self] message in
                Task { @MainActor in
                    self?.statusMessage = message
                    self?.isSpeaking = false
                    self?.arController?.stopTalking(restingEmotion: response.emotion)
                }
            }
        )
    }

    private func voiceProfile(for response: ChatResponse, persona: ObjectPersona) -> VoiceProfile {
        VoiceProfile(
            voiceIdentifier: persona.voiceProfile.voiceIdentifier,
            rate: response.rate,
            pitch: response.pitch,
            volume: response.volume
        )
    }

    private func detectionStatus(for detected: DetectedObject) -> String {
        if detected.confidence < 0.1 {
            return "I am not fully sure. I will treat it like an object for now."
        }

        let percent = Int(detected.confidence * 100)
        if detected.boundingBox != nil {
            return "I found a \(detected.label) (\(percent)%) and will place the face there."
        }

        return "I think this is a \(detected.label) (\(percent)%)."
    }

    private func shouldReadDetailedVisualContext(for message: String) -> Bool {
        let lowercased = message.lowercased()
        let detailKeywords = [
            "read",
            "word",
            "words",
            "text",
            "letter",
            "letters",
            "label",
            "written",
            "writing",
            "see",
            "look"
        ]

        return detailKeywords.contains { lowercased.contains($0) }
    }
}
