//
//  VLMChatModel.swift
//  kida
//
//  On-device vision-language model (SmolVLM, 4-bit) loaded from Hugging Face
//  via MLX. Technique ported from the VLM prototype; runs fully on-device.
//

import SwiftUI
import CoreImage
import MLX
import MLXLMCommon
import MLXVLM

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

@MainActor
@Observable
final class VLMChatModel {

    enum LoadState {
        case idle
        case downloading(Double)   // 0...1, first launch only
        case ready
        case failed(String)
    }

    var loadState: LoadState = .idle
    var messages: [ChatMessage] = []
    var isThinking = false

    private var container: ModelContainer?
    private var chat: [Chat.Message] = []

    // MARK: - Model loading

    func loadModel() async {
        guard container == nil else { return }
        print("[kida VLM] loadModel started")
        loadState = .downloading(0)
        do {
            // Keep MLX's GPU memory cache small so the app fits in iOS limits.
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

            let modelContainer = try await VLMModelFactory.shared.loadContainer(
                configuration: VLMRegistry.smolvlm
            ) { progress in
                Task { @MainActor in
                    self.loadState = .downloading(progress.fractionCompleted)
                }
            }
            container = modelContainer
            loadState = .ready
            print("[kida VLM] model READY")
        } catch {
            loadState = .failed(error.localizedDescription)
            print("[kida VLM] load FAILED: \(error)")
        }
    }

    // MARK: - Chat

    /// Called right after an object is scanned: the object introduces itself in
    /// its own voice, tone set by its personality, then invites questions.
    func startChat(for object: ScannedObject, image: UIImage) async {
        messages = []

        let system = """
        You ARE a \(object.objectName) talking to a young child (5-8 years old). \
        \(object.personality.promptStyle) \
        Always speak as the object itself ("I am…", "I can…"). Answer in 1-3 short, \
        simple, happy sentences. Never mention anything scary or for adults.
        """
        chat = [.system(system)]

        guard let ciImage = CIImage(image: image) else {
            messages.append(ChatMessage(role: .assistant,
                                        text: "Oops, I couldn't see myself! Try again!"))
            return
        }

        chat.append(.user(
            """
            Introduce yourself to the child in one or two happy sentences: say hi, \
            tell them what you are and your color, then ask: "What do you want to know?"
            """,
            images: [.ciImage(ciImage)]
        ))
        await generateReply()
    }

    /// Follow-up question typed by the child. The photo stays in the chat history.
    func ask(_ question: String) async {
        messages.append(ChatMessage(role: .user, text: question))
        chat.append(.user(question))
        await generateReply()
    }

    // MARK: - Identify (structured, one-shot — not part of the chat history)

    /// Ask the VLM for the object's name, personality, and a rough distance guess
    /// in a fixed format, then parse it. Separate from `startChat` so it doesn't
    /// pollute the conversation.
    ///
    /// Note: distance here is the VLM's *estimate* — small VLMs are weak at real
    /// distance, so treat near/middle/far as a coarse guess, not a measurement.
    func identify(image: UIImage) async -> (name: String, personality: Personality, distance: Distance)? {
        guard let container, let ciImage = CIImage(image: image) else { return nil }

        let prompt = """
        Look at the main object in the photo. Reply with ONLY this format:
        NAME | PERSONALITY | DISTANCE
        NAME = the object in 1 to 3 words.
        PERSONALITY = exactly one of: smart, cool, fancy, feminine, careful.
        DISTANCE = how far the object looks: exactly one of: near, middle, far.
        Do not add any other words.
        """

        let oneShot: [Chat.Message] = [
            .system("You identify objects for a kids app. Follow the format exactly."),
            .user(prompt, images: [.ciImage(ciImage)])
        ]

        do {
            let raw = try await Self.generate(container: container, chat: oneShot)
            return Self.parseIdentity(raw)
        } catch {
            return nil
        }
    }

    /// Split "NAME | PERSONALITY | DISTANCE" → typed tuple. Falls back gracefully
    /// if the model ignores the format (`"thing"`, `.cool`, `.middle`).
    private static func parseIdentity(_ raw: String) -> (name: String, personality: Personality, distance: Distance) {
        let parts = raw
            .split(separator: "|", maxSplits: 2)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let name = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "thing"
        let personalityWord = parts.count > 1 ? parts[1].lowercased() : ""
        let distanceWord = parts.count > 2 ? parts[2].lowercased() : ""

        let personality = Personality(rawValue: personalityWord) ?? .cool
        let distance = Distance(rawValue: distanceWord) ?? .middle

        return (name, personality, distance)
    }

    private func generateReply() async {
        guard let container else { return }
        isThinking = true
        defer { isThinking = false }

        do {
            let reply = try await Self.generate(container: container, chat: chat)
            chat.append(.assistant(reply))
            messages.append(ChatMessage(role: .assistant, text: reply))
        } catch {
            messages.append(ChatMessage(role: .assistant,
                                        text: "Hmm, my brain got tangled! (\(error.localizedDescription))"))
        }
    }

    /// nonisolated so the heavy work runs on the model's own executor, not the main thread.
    private nonisolated static func generate(
        container: ModelContainer,
        chat: [Chat.Message]
    ) async throws -> String {
        try await container.perform { context in
            var input = UserInput(chat: chat)
            // Shrink the photo before it goes into the model: much faster, same answers.
            input.processing.resize = CGSize(width: 448, height: 448)

            let prepared = try await context.processor.prepare(input: input)
            let parameters = GenerateParameters(maxTokens: 200, temperature: 0.6)

            var output = ""
            let stream = try MLXLMCommon.generate(
                input: prepared, parameters: parameters, context: context
            )
            for await generation in stream {
                if case .chunk(let text) = generation {
                    output += text
                }
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
