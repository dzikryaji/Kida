//
//  ScanView.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 03/07/26.
//

import SwiftUI
import SwiftData
import UIKit

struct ScanView: View {
    @ObservedObject var scanViewModel: ScanViewModel
    @Environment(\.modelContext) private var modelContext

    @State private var showSaveConfirmation = false
    @State private var showCloseConfirmation = false
    @State private var messageText = ""
    @State private var isListening = false
    @State private var speech = SpeechRecognitionService()
    @State private var sentMessageTrail: [SentMessageBubbleModel] = []

    @FocusState private var isTyping: Bool

    var isFullScreenMode: Bool {
        scanViewModel.isScanning || scanViewModel.placedAnchor != nil
    }

    private var hasPlacedObject: Bool {
        scanViewModel.placedAnchor != nil
    }

    private var shouldShowReadyOverlay: Bool {
        !scanViewModel.isScanning
            && !hasPlacedObject
            && !showSaveConfirmation
            && !showCloseConfirmation
    }

    private var canSend: Bool {
        !scanViewModel.isUnderstandingObject
            && !scanViewModel.isReplying
            && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var collectionItemName: String {
        scanViewModel.collectionItemName
    }

    private var collectionItemImage: Image {
        if let data = scanViewModel.capturedImageData,
           let image = UIImage(data: data) {
            return Image(uiImage: image)
        }

        return Image(systemName: "camera.viewfinder")
    }

    /// Sends `text` to the AI (reply → bubble + expression + voice) and clears the field.
    private func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !scanViewModel.isUnderstandingObject,
              !scanViewModel.isReplying
        else { return }

        appendSentMessage(trimmed)
        scanViewModel.sendMessage(trimmed)
        messageText = ""
        isTyping = false
    }

    private func send() { sendText(messageText) }

    private func appendSentMessage(_ text: String) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            sentMessageTrail.append(SentMessageBubbleModel(text: text))
            if sentMessageTrail.count > 3 {
                sentMessageTrail.removeFirst(sentMessageTrail.count - 3)
            }
        }
    }

    /// Mic → live speech-to-text into the field; the final transcript auto-sends.
    private func startListening() {
        isTyping = false
        messageText = ""
        isListening = true
        speech.startListening(
            onTranscript: { messageText = $0 },
            onFinish: { final in isListening = false; sendText(final) },
            onError: { _ in isListening = false }
        )
    }

    private func stopListening() {
        speech.stopListening(sendFinalTranscript: true)
        isListening = false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GeometryReader { geo in
                    ZStack {
                        ARViewContainer(scanViewModel: scanViewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if shouldShowReadyOverlay {
                            ScanReadyOverlay()
                                .transition(.opacity)
                        }
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: isFullScreenMode ? 0 : 34,
                                style: .continuous
                            )
                        )
                        .padding(.horizontal, isFullScreenMode ? 0 : 16)
                        .padding(
                            .top,
                            isFullScreenMode ? 0 : geo.safeAreaInsets.top + 64
                        )
                        .padding(
                            .bottom,
                            isFullScreenMode ? 0 : geo.safeAreaInsets.bottom + 100
                        )
                }
                .ignoresSafeArea(.all)
                // Local animation binding: this is the view that actually redraws
                // (frame/cornerRadius/padding) when isFullScreenMode flips, so it
                // needs its own .animation(value:) rather than relying on a
                // modifier attached higher up in ContentView.
                .animation(.easeInOut(duration: 0.3), value: isFullScreenMode)

                if showSaveConfirmation && !showCloseConfirmation {
                    SaveConfirmationOverlay(
                        itemName: collectionItemName,
                        itemImage: collectionItemImage,
                        onYes: {
                            let repository = ScannedItemRepository(modelContext: modelContext)
                            do {
                                try repository.add(
                                    imageData: scanViewModel.capturedImageData,
                                    imageSegmentedData: nil,
                                    itemDescription: scanViewModel.collectionItemDescription,
                                    objectName: collectionItemName
                                )
                            } catch {
                                print("Failed to save scanned item: \(error)")
                            }

                            withAnimation(
                                .spring(response: 0.35, dampingFraction: 0.85)
                            ) {
                                showSaveConfirmation = false
                            }

                            scanViewModel.removePlacedObject()
                        },
                        onNotNow: {
                            withAnimation(
                                .spring(response: 0.35, dampingFraction: 0.85)
                            ) {
                                showSaveConfirmation = false
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if !showSaveConfirmation && showCloseConfirmation {
                    CloseConfirmationOverlay(
                        itemName: collectionItemName,
                        onYes: {
                            withAnimation(
                                .spring(response: 0.35, dampingFraction: 0.85)
                            ) {
                                showCloseConfirmation = false
                            }

                            scanViewModel.removePlacedObject()
                        },
                        onNotNow: {
                            withAnimation(
                                .spring(response: 0.35, dampingFraction: 0.85)
                            ) {
                                showCloseConfirmation = false
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if hasPlacedObject {
                    VStack {
                        Spacer()

                        VStack(spacing: 12) {
                            SentMessageTrailView(messages: sentMessageTrail)
                                .padding(.horizontal, 22)
                                .allowsHitTesting(false)

                            HStack(spacing: 8) {
                                TextField("Text me", text: $messageText)
                                    .focused($isTyping)
                                    .textFieldStyle(.plain)
                                    .disabled(scanViewModel.isUnderstandingObject || scanViewModel.isReplying)
                                    .submitLabel(.send)
                                    .onSubmit { send() }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .glassEffect(
                                        .regular.tint(Color.white.opacity(0.10)).interactive(),
                                        in: .capsule
                                    )

                                Button {
                                    if isListening {
                                        stopListening()
                                    } else if canSend {
                                        send()
                                    } else if isTyping {
                                        isTyping.toggle()
                                    } else {
                                        startListening()
                                    }
                                } label: {
                                    if isListening {
                                        Image(systemName: "stop.fill")
                                            .font(.system(size: 16, weight: .bold))
                                            .frame(width: 36, height: 36)
                                    } else if canSend {
                                        Image(systemName: "arrow.up")
                                            .font(.system(size: 16, weight: .bold))
                                            .frame(width: 36, height: 36)
                                    } else if isTyping {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 16, weight: .medium))
                                            .frame(width: 36, height: 36)
                                    } else {
                                        Image(systemName: "microphone.fill")
                                            .font(.system(size: 16, weight: .medium))
                                            .frame(width: 36, height: 36)
                                    }
                                }
                                .foregroundStyle(isListening ? Color.red : Color(.systemGray))
                                .disabled(scanViewModel.isUnderstandingObject || scanViewModel.isReplying)
                                .padding(2)
                                .transition(.scale.combined(with: .opacity))
                                .glassEffect(.regular.tint(Color.white.opacity(0.10)).interactive(), in: .capsule)

                            }
                            .padding(.trailing, isTyping ? 6 : 6)
                            .padding(.horizontal, 16)
                        }
                        .padding(.bottom, 12)
                        .animation(.easeInOut(duration: 0.2), value: isTyping)
                    }
                    .transition(.opacity)
                }

                if scanViewModel.isScanning {
                    ScanningOverlay()
                        .transition(.opacity)
                }
            }
            .toolbar {
                if hasPlacedObject {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: {
                            withAnimation(
                                .spring(response: 0.35, dampingFraction: 0.85)
                            ) {
                                showCloseConfirmation = true
                            }
                        }) {
                            Label("Close", systemImage: "xmark")
                        }
                        .disabled(
                            showCloseConfirmation || showSaveConfirmation
                        )
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            withAnimation(
                                .spring(response: 0.35, dampingFraction: 0.85)
                            ) {
                                showSaveConfirmation = true
                            }
                        }) {
                            Label(
                                "Save",
                                systemImage: "square.and.arrow.down"
                            )
                        }
                        .disabled(
                            showCloseConfirmation || showSaveConfirmation
                        )
                    }
                }

            }
            .onChange(of: hasPlacedObject) { _, hasObject in
                if !hasObject {
                    sentMessageTrail.removeAll()
                }
            }
        }
    }
}

private struct SentMessageBubbleModel: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

private struct SentMessageTrailView: View {
    let messages: [SentMessageBubbleModel]

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                SentMessageBubble(
                    text: message.text,
                    opacity: opacity(for: index),
                    maxWidthFraction: maxWidthFraction(for: index)
                )
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: messages)
    }

    private func opacity(for index: Int) -> Double {
        let age = messages.count - 1 - index
        switch age {
        case 0: return 1
        case 1: return 0.78
        default: return 0.48
        }
    }

    private func maxWidthFraction(for index: Int) -> CGFloat {
        let age = messages.count - 1 - index
        return age == 0 ? 0.7 : 0.78
    }
}

private struct SentMessageBubble: View {
    let text: String
    let opacity: Double
    let maxWidthFraction: CGFloat

    private var bubbleHeight: CGFloat {
        text.count > 34 ? 72 : 54
    }

    var body: some View {
        GeometryReader { proxy in
            HStack {
                Spacer(minLength: 44)

                Text(text)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.88)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                    .frame(maxWidth: proxy.size.width * maxWidthFraction)
                    .background {
                        SentMessageBubbleShape()
                            .fill(Color(red: 0.62, green: 0.42, blue: 0.95).opacity(0.16))
                    }
                    .glassEffect(
                        .regular.tint(Color(red: 0.66, green: 0.42, blue: 1.0).opacity(0.24)),
                        in: SentMessageBubbleShape()
                    )
                    .shadow(color: Color.white.opacity(0.14), radius: 7, y: -2)
                    .shadow(color: Color.black.opacity(0.18), radius: 12, y: 6)
                    .opacity(opacity)
            }
        }
        .frame(height: bubbleHeight)
    }
}

private struct SentMessageBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tailWidth: CGFloat = min(17, rect.width * 0.12)
        let tailHeight: CGFloat = 13
        let cornerRadius: CGFloat = min(18, rect.height * 0.38)
        let bubbleRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height - tailHeight
        )
        let radius = min(
            cornerRadius,
            bubbleRect.width / 2,
            bubbleRect.height / 2
        )
        let tailMidX = min(
            max(bubbleRect.maxX - 34, bubbleRect.minX + radius + tailWidth),
            bubbleRect.maxX - radius - tailWidth / 2
        )
        let tailStartX = tailMidX - tailWidth / 2
        let tailEndX = tailMidX + tailWidth / 2

        var path = Path()
        path.move(to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.minY))
        path.addLine(to: CGPoint(x: bubbleRect.maxX - radius, y: bubbleRect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bubbleRect.maxX, y: bubbleRect.minY + radius),
            control: CGPoint(x: bubbleRect.maxX, y: bubbleRect.minY)
        )
        path.addLine(to: CGPoint(x: bubbleRect.maxX, y: bubbleRect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: bubbleRect.maxX - radius, y: bubbleRect.maxY),
            control: CGPoint(x: bubbleRect.maxX, y: bubbleRect.maxY)
        )
        path.addLine(to: CGPoint(x: tailEndX, y: bubbleRect.maxY))
        path.addLine(to: CGPoint(x: tailMidX + 3, y: rect.maxY))
        path.addLine(to: CGPoint(x: tailStartX, y: bubbleRect.maxY))
        path.addLine(to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bubbleRect.minX, y: bubbleRect.maxY - radius),
            control: CGPoint(x: bubbleRect.minX, y: bubbleRect.maxY)
        )
        path.addLine(to: CGPoint(x: bubbleRect.minX, y: bubbleRect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: bubbleRect.minX + radius, y: bubbleRect.minY),
            control: CGPoint(x: bubbleRect.minX, y: bubbleRect.minY)
        )
        path.closeSubpath()

        return path
    }
}

#Preview {
    let viewModel = ScanViewModel()

    ScanView(scanViewModel: viewModel)
}


/// Shows the camera is ready before the user taps an object. It is intentionally
/// non-interactive so the AR tap gesture underneath still receives the touch.
struct ScanReadyOverlay: View {
    var body: some View {
        ZStack {
            ScanFocusFrame(
                color: .white.opacity(0.86),
                shadowColor: .black.opacity(0.35),
                lineWidth: 3
            )
            .frame(width: 156, height: 156)

            VStack {
                Spacer()

                ScanStatusPill(
                    icon: "viewfinder",
                    title: "Center object",
                    subtitle: "Tap to scan"
                )
                .padding(.bottom, 22)
            }
            .padding(.horizontal, 16)
        }
        .allowsHitTesting(false)
    }
}

/// Shown while `ScanViewModel` is running SAM segmentation on the tapped
/// object. Its visible duration is whatever segmentation actually takes -
/// there's no fixed timer behind it anymore.
struct ScanningOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var sweep = false

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                ZStack {
                    ScanFocusFrame(
                        color: Color.cyan.opacity(0.72),
                        shadowColor: Color.cyan.opacity(0.75),
                        lineWidth: 6
                    )
                    .frame(width: 166, height: 166)
                    .blur(radius: 0.3)
                    .scaleEffect(pulse ? 1.04 : 0.98)
                    .opacity(pulse ? 0.65 : 0.95)

                    ScanFocusFrame(
                        color: .white.opacity(0.96),
                        shadowColor: .black.opacity(0.28),
                        lineWidth: 3
                    )
                    .frame(width: 154, height: 154)

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            Color.white.opacity(0.82),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 9])
                        )
                        .frame(width: 46, height: 46)
                        .shadow(color: .cyan.opacity(0.45), radius: 10)

                    if !reduceMotion {
                        ScanSweepLine()
                            .frame(width: 142, height: 142)
                            .offset(y: sweep ? 48 : -48)
                    }
                }
                .frame(width: 180, height: 180)

                ScanStatusPill(
                    icon: "sparkles",
                    title: "Scanning object",
                    subtitle: "Hold steady"
                )
                .scaleEffect(pulse ? 1.02 : 1)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            pulse = false
            sweep = false

            // IMPORTANT: don't start the repeatForever animations synchronously
            // inside onAppear. onAppear fires while SwiftUI is still inside the
            // transaction created by this view's own `.transition(.opacity)`
            // insertion. If withAnimation(...repeatForever...) runs in that same
            // transaction, the repeating animation gets scoped to the transition's
            // transaction and is torn down as soon as that transaction finishes -
            // which is why the sweep line only went down once instead of
            // bouncing back and forth forever.
            //
            // Deferring to the next run loop tick lets the insertion transition
            // commit first, so these animations start in their own transaction
            // and loop indefinitely as intended.
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    sweep = true
                }
            }
        }
        .onDisappear {
            // Reset so re-appearing starts clean rather than mid-cycle.
            pulse = false
            sweep = false
        }
    }
}

private struct ScanSweepLine: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.cyan.opacity(0),
                        Color.cyan.opacity(0.95),
                        Color.white.opacity(0.92),
                        Color.cyan.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 3)
            .shadow(color: .cyan.opacity(0.75), radius: 12)
            .mask(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ScanStatusPill: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.18)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Capsule().fill(Color.black.opacity(0.2)))
        .glassEffect(.regular.tint(Color.white.opacity(0.10)), in: .capsule)
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }
}

private struct ScanFocusFrame: View {
    let color: Color
    let shadowColor: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            ScanCornerShape(corner: .topLeading)
                .stroke(style: stroke)
                .frame(width: 42, height: 42)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ScanCornerShape(corner: .topTrailing)
                .stroke(style: stroke)
                .frame(width: 42, height: 42)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            ScanCornerShape(corner: .bottomLeading)
                .stroke(style: stroke)
                .frame(width: 42, height: 42)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            ScanCornerShape(corner: .bottomTrailing)
                .stroke(style: stroke)
                .frame(width: 42, height: 42)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .foregroundStyle(color)
        .shadow(color: shadowColor, radius: 8, y: 2)
    }

    private var stroke: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }
}

private struct ScanCornerShape: Shape {
    enum Corner {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    let corner: Corner

    func path(in rect: CGRect) -> Path {
        var path = Path()

        switch corner {
        case .topLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        case .topTrailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottomLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottomTrailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        return path
    }
}
