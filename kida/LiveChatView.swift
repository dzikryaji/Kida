//
//  LiveChatView.swift
//  kida
//
//  Interactive chat overlay over the live camera (PRD §4b). Floating speech
//  bubbles, NOT a messenger list: system/object bubbles top-LEFT (gold),
//  user bubbles bottom-RIGHT (purple), max 3 visible (oldest fades out),
//  stack capped at mid-screen. Input pill + mic pinned to the bottom.
//

import SwiftUI

// MARK: - Design tokens (PRD §4b)

enum ChatStyle {
    static let systemFillTop    = Color(red: 0.953, green: 0.788, blue: 0.412) // #F3C969
    static let systemFillBottom = Color(red: 0.878, green: 0.659, blue: 0.243) // #E0A83E
    static let systemText       = Color(red: 0.290, green: 0.231, blue: 0.122) // #4A3B1F

    static let userFillTop      = Color(red: 0.690, green: 0.416, blue: 0.902) // #B06AE6
    static let userFillBottom   = Color(red: 0.545, green: 0.247, blue: 0.839) // #8B3FD6
    static let userText         = Color.white

    static let corner: CGFloat         = 20
    static let tailSize: CGFloat       = 12
    static let hPadding: CGFloat       = 14
    static let vPadding: CGFloat       = 10
    static let maxWidthFraction        = 0.72
    static let gap: CGFloat            = 12
    static let maxVisibleBubbles       = 3
}

// MARK: - Speech bubble

struct SpeechBubble: View {
    enum Side { case system, user }

    let text: String
    let side: Side

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(side == .system ? ChatStyle.systemText : ChatStyle.userText)
            .padding(.horizontal, ChatStyle.hPadding)
            .padding(.vertical, ChatStyle.vPadding)
            .background(
                BubbleShape(tailOnLeft: side == .system)
                    .fill(gradient)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            )
            .padding(.bottom, ChatStyle.tailSize) // room for the tail
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: side == .system
                ? [ChatStyle.systemFillTop, ChatStyle.systemFillBottom]
                : [ChatStyle.userFillTop, ChatStyle.userFillBottom],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// Rounded rect + small triangle tail on the bottom edge. Tail sits near the
/// left corner for system bubbles, near the right corner for user bubbles.
struct BubbleShape: Shape {
    let tailOnLeft: Bool

    func path(in rect: CGRect) -> Path {
        let tail = ChatStyle.tailSize
        let body = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: rect.height)

        var path = Path(roundedRect: body,
                        cornerRadius: ChatStyle.corner,
                        style: .continuous)

        let tailX = tailOnLeft
            ? rect.minX + ChatStyle.corner + tail
            : rect.maxX - ChatStyle.corner - tail

        var tailPath = Path()
        tailPath.move(to: CGPoint(x: tailX - tail, y: rect.maxY - 1))
        tailPath.addLine(to: CGPoint(x: tailX + tail, y: rect.maxY - 1))
        tailPath.addLine(to: CGPoint(x: tailX, y: rect.maxY + tail))
        tailPath.closeSubpath()

        path.addPath(tailPath)
        return path
    }
}

// MARK: - Thinking bubble ("…" while the VLM generates)

struct ThinkingBubble: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(ChatStyle.systemText.opacity(phase == i ? 1 : 0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, ChatStyle.hPadding + 4)
        .padding(.vertical, ChatStyle.vPadding + 4)
        .background(
            BubbleShape(tailOnLeft: true)
                .fill(LinearGradient(
                    colors: [ChatStyle.systemFillTop, ChatStyle.systemFillBottom],
                    startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        )
        .padding(.bottom, ChatStyle.tailSize)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeInOut(duration: 0.25)) { phase = (phase + 1) % 3 }
            }
        }
    }
}

// MARK: - Input bar (frosted pill + mic)

struct ChatInputBar: View {
    @Binding var text: String
    var isEnabled: Bool
    var onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("What do you want to ask?", text: $text)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.thinMaterial, in: Capsule())
                .submitLabel(.send)
                .onSubmit(onSend)

            // Mic = phase-8 placeholder (voice input later).
            Button {
                // TODO: voice input (Phase 8)
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .disabled(!isEnabled)
    }
}

// MARK: - Chat overlay (arranges everything over the camera)

struct ChatOverlay: View {
    let messages: [ChatMessage]
    let isThinking: Bool
    @Binding var draft: String
    var onSend: () -> Void

    /// Last N messages only — oldest disappears beyond the cap (FIFO).
    private var visibleMessages: [ChatMessage] {
        Array(messages.suffix(ChatStyle.maxVisibleBubbles))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Bubble stack: grows from the top, capped at mid-screen.
                VStack(spacing: ChatStyle.gap) {
                    ForEach(visibleMessages) { message in
                        bubbleRow(message, screenWidth: geo.size.width)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    }
                    if isThinking {
                        HStack {
                            ThinkingBubble()
                            Spacer()
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                // Bubbles hug the middle of the screen: the stack lives in the
                // top half but pins to its BOTTOM edge (= mid-screen), growing
                // upward as messages arrive. Never reaches the Dynamic Island.
                .frame(maxWidth: .infinity,
                       maxHeight: geo.size.height / 2,
                       alignment: .bottom)

                Spacer()

                ChatInputBar(draft: $draft, onSend: onSend, thinking: isThinking)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85),
                       value: messages.count)
            .animation(.easeInOut(duration: 0.2), value: isThinking)
        }
    }

    @ViewBuilder
    private func bubbleRow(_ message: ChatMessage, screenWidth: CGFloat) -> some View {
        let maxW = screenWidth * ChatStyle.maxWidthFraction
        HStack {
            if message.role == .assistant {
                SpeechBubble(text: message.text, side: .system)
                    .frame(maxWidth: maxW, alignment: .leading)
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                SpeechBubble(text: message.text, side: .user)
                    .frame(maxWidth: maxW, alignment: .trailing)
            }
        }
    }
}

// Convenience init so call sites read naturally.
private extension ChatInputBar {
    init(draft: Binding<String>, onSend: @escaping () -> Void, thinking: Bool) {
        self.init(text: draft, isEnabled: !thinking, onSend: onSend)
    }
}

// MARK: - Preview

#Preview("Chat overlay") {
    struct PreviewWrapper: View {
        @State var draft = ""
        var body: some View {
            ZStack {
                Color(white: 0.75).ignoresSafeArea() // stand-in for camera
                ChatOverlay(
                    messages: [
                        ChatMessage(role: .assistant,
                                    text: "Hi! I'm a cream mug! What do you want to know?"),
                        ChatMessage(role: .user, text: "What are you usually used for?"),
                        ChatMessage(role: .user, text: "how much are you"),
                    ],
                    isThinking: true,
                    draft: $draft,
                    onSend: {}
                )
            }
        }
    }
    return PreviewWrapper()
}
