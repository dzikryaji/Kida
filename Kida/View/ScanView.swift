//
//  ScanView.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 03/07/26.
//

import SwiftUI

struct ScanView: View {
    @ObservedObject var scanViewModel: ScanViewModel

    @State private var showSaveConfirmation = false
    @State private var showCloseConfirmation = false
    @State private var messageText = ""
    @State private var isListening = false
    @State private var speech = SpeechRecognitionService()

    @FocusState private var isTyping: Bool

    var isFullScreenMode: Bool {
        scanViewModel.isScanning || scanViewModel.placedAnchor != nil
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends `text` to the AI (reply → bubble + expression + voice) and clears the field.
    private func sendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        scanViewModel.sendMessage(trimmed)
        messageText = ""
        isTyping = false
    }

    private func send() { sendText(messageText) }

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
                    ARViewContainer(scanViewModel: scanViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cornerRadius(isFullScreenMode ? 0 : 34)
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
                        itemName: "Mug",
                        itemImage: Image(systemName: "cup.and.saucer.fill"),
                        onYes: {
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
                        itemName: "Mug",
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

                if isFullScreenMode {
                    VStack {
                        Spacer()

                        HStack(spacing: 8) {
                            TextField("Text me", text: $messageText)
                                .focused($isTyping)
                                .textFieldStyle(.plain)
                                .submitLabel(.send)
                                .onSubmit { send() }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .glassEffect(
                                    .regular.interactive(),
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
                            .disabled(scanViewModel.isReplying)
                            .padding(2)
                            .transition(.scale.combined(with: .opacity))
                            .glassEffect(.regular.interactive(), in: .capsule)

                        }
                        .padding(.trailing, isTyping ? 6 : 6)
                        .padding(.horizontal, 16)
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
                if isFullScreenMode {
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
        }
    }
}

#Preview {
    let viewModel = ScanViewModel()

    ScanView(scanViewModel: viewModel)
}


/// Shown while `ScanViewModel` is running SAM segmentation on the tapped
/// object. Its visible duration is whatever segmentation actually takes -
/// there's no fixed timer behind it anymore.
struct ScanningOverlay: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
        .allowsHitTesting(false)
    }
}
