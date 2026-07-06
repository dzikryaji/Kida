import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = KidaViewModel()
    @State private var screen: KidaScreen = .home
    @State private var showSavePrompt = false

    var body: some View {
        ZStack {
            if screen == .discover {
                ARExperienceView(
                    viewModel: viewModel,
                    screen: $screen,
                    showSavePrompt: $showSavePrompt
                )
            } else {
                KidaHomeView(
                    viewModel: viewModel,
                    screen: $screen
                )
            }
        }
        .animation(.easeInOut(duration: 0.22), value: screen)
        .onChange(of: viewModel.persona?.id) {
            showSavePrompt = viewModel.persona != nil
        }
    }
}

private struct KidaHomeView: View {
    @ObservedObject var viewModel: KidaViewModel
    @Binding var screen: KidaScreen

    var body: some View {
        ZStack {
            KidaHomeBackground()

            VStack(spacing: 24) {
                Spacer(minLength: 34)

                VStack(spacing: 8) {
                    Text("KIDA")
                        .font(.system(size: 58, weight: .black, design: .rounded))
                        .foregroundStyle(KidaPalette.purple)
                        .shadow(color: KidaPalette.deepPurple.opacity(0.28), radius: 0, x: 0, y: 3)

                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                        Text("Bring nearby things to life")
                        Image(systemName: "sparkle")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(KidaPalette.goldInk.opacity(0.78))
                }

                KidaMascotView()
                    .frame(width: 148, height: 148)

                VStack(spacing: 14) {
                    HomeActionButton(
                        title: "Discover",
                        iconName: "viewfinder",
                        style: .primary
                    ) {
                        screen = .discover
                    }

                    HomeActionButton(
                        title: "My Pals",
                        iconName: "heart.text.square.fill",
                        style: .secondary
                    ) {
                        screen = .pals
                    }
                }
                .padding(.horizontal, 32)

                if screen == .pals {
                    MyPalsPanel(viewModel: viewModel) {
                        screen = .home
                    }
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Spacer(minLength: 82)
                }
            }
        }
    }
}

private struct ARExperienceView: View {
    @ObservedObject var viewModel: KidaViewModel
    @Binding var screen: KidaScreen
    @Binding var showSavePrompt: Bool

    var body: some View {
        ZStack {
            ARViewContainer(viewModel: viewModel)
                .ignoresSafeArea()

            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if !viewModel.isFacePlaced {
                DetectionBoxOverlay(
                    segmentation: viewModel.detectedObject?.segmentation,
                    boundingBox: viewModel.detectedObject?.boundingBox
                )
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                ARTopBar(
                    viewModel: viewModel,
                    onBack: { screen = .home },
                    onSave: { showSavePrompt = true }
                )
                .padding(.horizontal, 14)
                .padding(.top, 12)

                Spacer()

                FloatingConversation(viewModel: viewModel)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)

                ARBottomControls(viewModel: viewModel)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }

            if isDangerousObject {
                DangerWarningView()
                    .padding(.horizontal, 26)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }

            if showSavePrompt, viewModel.persona != nil {
                SavePalPrompt(viewModel: viewModel) {
                    showSavePrompt = false
                }
                .padding(.horizontal, 34)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
    }

    private var isDangerousObject: Bool {
        guard let label = viewModel.detectedObject?.label.lowercased() else {
            return false
        }

        return ["knife", "scissors", "fire", "stove", "oven", "weapon"].contains(label)
    }
}

private struct ARTopBar: View {
    @ObservedObject var viewModel: KidaViewModel
    var onBack: () -> Void
    var onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CircleIconButton(iconName: "chevron.left", action: onBack)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.persona?.name ?? "Discover")
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(viewModel.statusMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2)
            }

            Spacer()

            if let detectedObject = viewModel.detectedObject {
                DetectionBadge(detectedObject: detectedObject)
            }

            CircleIconButton(iconName: "heart.fill", action: onSave)
                .opacity(viewModel.persona == nil ? 0.42 : 1)
                .disabled(viewModel.persona == nil)
        }
    }
}

private struct DetectionBoxOverlay: View {
    var segmentation: ObjectSegmentation?
    var boundingBox: CGRect?

    var body: some View {
        GeometryReader { proxy in
            if let maskPreviewImage = segmentation?.maskPreviewImage {
                Image(uiImage: maskPreviewImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .opacity(0.92)
            }

            if let boundingBox = segmentation?.boundingBox ?? boundingBox {
                let rect = screenRect(for: boundingBox, size: proxy.size)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(segmentation == nil ? KidaPalette.lilac : KidaPalette.yellow, lineWidth: 3)
                    .shadow(
                        color: (segmentation == nil ? KidaPalette.lilac : KidaPalette.yellow).opacity(0.88),
                        radius: 8,
                        x: 0,
                        y: 0
                    )
                    .frame(width: max(rect.width, 86), height: max(rect.height, 86))
                    .position(x: rect.midX, y: rect.midY)
            } else {
                TargetReticle()
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.42)
            }
        }
    }

    private func screenRect(for normalizedBoundingBox: CGRect, size: CGSize) -> CGRect {
        let width = normalizedBoundingBox.width * size.width
        let height = normalizedBoundingBox.height * size.height
        let x = normalizedBoundingBox.minX * size.width
        let y = (1 - normalizedBoundingBox.maxY) * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct FloatingConversation: View {
    @ObservedObject var viewModel: KidaViewModel

    var body: some View {
        VStack(spacing: 8) {
            if let objectMessage = viewModel.messages.last(where: { $0.role == .object }) {
                FloatingBubble(
                    text: objectMessage.text,
                    role: .object
                )
            }

            if let childMessage = viewModel.messages.last(where: { $0.role == .child }) {
                FloatingBubble(
                    text: childMessage.text,
                    role: .child
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct FloatingBubble: View {
    var text: String
    var role: ChatMessage.Role

    var body: some View {
        Text(text)
            .font(.callout.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(4)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 260, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: role == .object ? .bottomLeading : .bottomTrailing) {
                BubbleTail()
                    .fill(background)
                    .frame(width: 18, height: 14)
                    .offset(x: role == .object ? 18 : -18, y: 10)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
    }

    private var background: Color {
        role == .object ? KidaPalette.purple.opacity(0.94) : KidaPalette.yellow.opacity(0.95)
    }
}

private struct ARBottomControls: View {
    @ObservedObject var viewModel: KidaViewModel

    var body: some View {
        VStack(spacing: 12) {
            if let persona = viewModel.persona {
                EmotionChip(emotion: persona.emotionStyle, isSpeaking: viewModel.isSpeaking)
            }

            HStack(spacing: 10) {
                Button {
                    viewModel.scanCurrentObject()
                } label: {
                    ZStack {
                        Circle()
                            .fill(KidaPalette.yellow)
                            .frame(width: 62, height: 62)
                            .shadow(color: KidaPalette.yellow.opacity(0.42), radius: 12, x: 0, y: 5)

                        if viewModel.isScanning {
                            ProgressView()
                                .tint(KidaPalette.goldInk)
                        } else {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 25, weight: .black))
                                .foregroundStyle(KidaPalette.goldInk)
                        }
                    }
                }
                .disabled(viewModel.isScanning)
                .accessibilityLabel("Scan object")

                Button {
                    viewModel.toggleVoiceInput()
                } label: {
                    Image(systemName: viewModel.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(viewModel.persona == nil ? .white.opacity(0.54) : .white)
                        .frame(width: 48, height: 48)
                        .background(viewModel.isListening ? KidaPalette.coral : KidaPalette.purple, in: Circle())
                        .shadow(color: KidaPalette.purple.opacity(0.34), radius: 10, x: 0, y: 4)
                }
                .disabled(viewModel.persona == nil)
                .accessibilityLabel(viewModel.isListening ? "Stop listening and send" : "Ask with voice")

                TextComposerButton(viewModel: viewModel)
            }
        }
    }
}

private struct TextComposerButton: View {
    @ObservedObject var viewModel: KidaViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Type", text: $viewModel.inputText)
                .focused($isFocused)
                .font(.body.weight(.semibold))
                .foregroundStyle(KidaPalette.ink)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.send)
                .onSubmit {
                    viewModel.sendCurrentMessage()
                }
                .frame(width: isFocused ? 144 : 62, height: 44)
                .padding(.horizontal, 10)
                .background(Color.white.opacity(0.92), in: Capsule())
                .disabled(viewModel.persona == nil)

            Button {
                viewModel.sendCurrentMessage()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(canSend ? KidaPalette.purple : Color.white.opacity(0.2), in: Circle())
            }
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        viewModel.persona != nil && !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct DetectionBadge: View {
    var detectedObject: DetectedObject

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
            Text(title)
        }
        .font(.caption.weight(.black))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(KidaPalette.purple.opacity(0.82), in: Capsule())
    }

    private var iconName: String {
        if detectedObject.segmentation != nil {
            return "scope"
        }

        return detectedObject.boundingBox == nil ? "sparkle.magnifyingglass" : "checkmark.seal.fill"
    }

    private var title: String {
        if detectedObject.segmentation != nil && detectedObject.confidence == 0 {
            return "Segmented"
        }

        return "\(detectedObject.label.capitalized) \(Int(detectedObject.confidence * 100))%"
    }
}

private struct EmotionChip: View {
    var emotion: Emotion
    var isSpeaking: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSpeaking ? "waveform" : "face.smiling")
            Text(isSpeaking ? "Speaking" : emotion.displayName)
        }
        .font(.caption.weight(.black))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(KidaPalette.purple.opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: KidaPalette.purple.opacity(0.34), radius: 10, x: 0, y: 4)
    }
}

private struct SavePalPrompt: View {
    @ObservedObject var viewModel: KidaViewModel
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Save \(viewModel.persona?.name ?? "this pal") to My Pals?")
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Button {
                viewModel.saveCurrentPersona()
                dismiss()
            } label: {
                Label("Yes", systemImage: "heart.fill")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(KidaPalette.goldInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(KidaPalette.yellow, in: Capsule())
            }

            Button {
                dismiss()
            } label: {
                Text("Not now")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 20, x: 0, y: 10)
    }
}

private struct MyPalsPanel: View {
    @ObservedObject var viewModel: KidaViewModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: close) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(KidaPalette.purple)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.8), in: Circle())
                }

                Text("My Pals")
                    .font(.title3.weight(.black))
                    .foregroundStyle(KidaPalette.deepPurple)

                Spacer()
            }

            if viewModel.savedPersonas.isEmpty {
                Text("Saved object friends will appear here.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(KidaPalette.deepPurple.opacity(0.72))
                    .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(viewModel.savedPersonas) { persona in
                        PalCard(persona: persona)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(KidaPalette.lilac.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct PalCard: View {
    var persona: ObjectPersona

    var body: some View {
        VStack(spacing: 7) {
            KidaMiniFaceView(emotion: persona.emotionStyle)
                .frame(width: 54, height: 54)

            Text(persona.name)
                .font(.caption.weight(.black))
                .foregroundStyle(KidaPalette.deepPurple)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(persona.objectLabel.capitalized)
                .font(.caption2.weight(.bold))
                .foregroundStyle(KidaPalette.goldInk.opacity(0.75))
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(KidaPalette.paleYellow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DangerWarningView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26, weight: .black))
                .foregroundStyle(.white)

            Text("This can be dangerous")
                .font(.headline.weight(.black))
                .foregroundStyle(.white)

            Text("Ask an adult to help.")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(16)
        .background(KidaPalette.coral.opacity(0.88), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: KidaPalette.coral.opacity(0.35), radius: 18, x: 0, y: 8)
    }
}

private struct HomeActionButton: View {
    enum Style {
        case primary
        case secondary
    }

    var title: String
    var iconName: String
    var style: Style
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Spacer()

                Text(title)
                    .font(.title3.weight(.black))

                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .black))
                    .frame(width: 40, height: 40)
                    .background(iconBackground, in: Circle())

                Spacer()
            }
            .foregroundStyle(foreground)
            .frame(height: 68)
            .background(background, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(style == .primary ? 0.28 : 0.7), lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: 13, x: 0, y: 8)
        }
    }

    private var foreground: Color {
        style == .primary ? .white : KidaPalette.goldInk
    }

    private var background: Color {
        style == .primary ? KidaPalette.purple : KidaPalette.paleYellow
    }

    private var iconBackground: Color {
        style == .primary ? KidaPalette.lilac.opacity(0.44) : KidaPalette.yellow.opacity(0.7)
    }

    private var shadowColor: Color {
        style == .primary ? KidaPalette.purple.opacity(0.3) : KidaPalette.yellow.opacity(0.22)
    }
}

private struct CircleIconButton: View {
    var iconName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.black.opacity(0.22), in: Circle())
        }
    }
}

private struct TargetReticle: View {
    var body: some View {
        ZStack {
            VStack {
                HStack {
                    ReticleCorner()
                    Spacer()
                    ReticleCorner().rotationEffect(.degrees(90))
                }
                Spacer()
                HStack {
                    ReticleCorner().rotationEffect(.degrees(270))
                    Spacer()
                    ReticleCorner().rotationEffect(.degrees(180))
                }
            }

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(KidaPalette.lilac.opacity(0.36), lineWidth: 1)
                .frame(width: 98, height: 98)
        }
        .frame(width: 156, height: 156)
    }
}

private struct ReticleCorner: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(KidaPalette.lilac)
                .frame(width: 34, height: 4)
            Rectangle()
                .fill(KidaPalette.lilac)
                .frame(width: 4, height: 34)
        }
        .frame(width: 34, height: 34)
        .shadow(color: KidaPalette.lilac.opacity(0.8), radius: 5, x: 0, y: 0)
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct KidaMascotView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(KidaPalette.paleYellow)
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(KidaPalette.deepPurple, lineWidth: 3)
                )
                .frame(width: 94, height: 104)
                .offset(y: 8)

            HStack(spacing: 16) {
                Circle().fill(KidaPalette.deepPurple).frame(width: 10, height: 10)
                Circle().fill(KidaPalette.deepPurple).frame(width: 10, height: 10)
            }
            .offset(y: -2)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(KidaPalette.coral)
                .frame(width: 24, height: 13)
                .offset(y: 20)

            Image(systemName: "hand.wave.fill")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(KidaPalette.paleYellow)
                .shadow(color: KidaPalette.deepPurple, radius: 0, x: 0, y: 0)
                .offset(x: -61, y: 22)

            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(KidaPalette.yellow)
                .offset(x: 64, y: -38)
        }
    }
}

private struct KidaMiniFaceView: View {
    var emotion: Emotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(KidaPalette.lilac.opacity(0.5), lineWidth: 1)
                )

            HStack(spacing: 7) {
                Circle().fill(KidaPalette.deepPurple).frame(width: 7, height: 7)
                Circle().fill(KidaPalette.deepPurple).frame(width: 7, height: 7)
            }
            .offset(y: -5)

            Text(emotion == .surprised ? "o" : "u")
                .font(.caption.weight(.black))
                .foregroundStyle(KidaPalette.coral)
                .offset(y: 10)
        }
    }
}

private struct KidaHomeBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                KidaPalette.cream,
                KidaPalette.cream,
                KidaPalette.lilac.opacity(0.22)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private enum KidaScreen {
    case home
    case discover
    case pals
}

private enum KidaPalette {
    static let purple = Color(red: 0.45, green: 0.29, blue: 0.87)
    static let deepPurple = Color(red: 0.18, green: 0.10, blue: 0.39)
    static let lilac = Color(red: 0.75, green: 0.55, blue: 1.0)
    static let yellow = Color(red: 1.0, green: 0.78, blue: 0.20)
    static let paleYellow = Color(red: 1.0, green: 0.92, blue: 0.58)
    static let cream = Color(red: 1.0, green: 0.97, blue: 0.89)
    static let coral = Color(red: 0.94, green: 0.35, blue: 0.31)
    static let goldInk = Color(red: 0.50, green: 0.32, blue: 0.05)
    static let ink = Color(red: 0.12, green: 0.11, blue: 0.17)
}
