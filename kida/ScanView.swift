//
//  ScanView.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 03/07/26.
//

import SwiftUI

struct ScanView: View {
    @Binding var isScanMode: Bool
    let scanChat: ScanChatModel

    var body: some View {
        NavigationStack {
            ZStack {
                CameraView(isScanMode: $isScanMode, scanChat: scanChat)
                    .cornerRadius(isScanMode ? 0 : 34)
                    .padding(.horizontal, isScanMode ? 0 : 16)
                    .padding(.vertical, isScanMode ? 0 : 10)
                    .ignoresSafeArea(isScanMode ? .all : [])
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isScanMode)
    }
}
#Preview {
    struct PreviewWrapper: View {
        @State var isScanMode = false
        var body: some View {
            ScanView(isScanMode: $isScanMode, scanChat: ScanChatModel())
        }
    }
    return PreviewWrapper()
}

struct CameraView: View {
    @Binding var isScanMode: Bool
    @State private var showSaveConfirmation = false
    @State private var showCloseConfirmation = false
    @Bindable var scanChat: ScanChatModel

    private var overlaysBlocked: Bool {
        showSaveConfirmation || showCloseConfirmation
    }

    var body: some View {
        ZStack {
            ARViewContainer(
                onARViewReady: { scanChat.arView = $0 },
                onTap: { point in
                    // Single tap path (UIKit recognizer). SwiftUI .onTapGesture
                    // can't be used here: it loses to the UIKit recognizer and
                    // never fires.
                    guard !overlaysBlocked else { return }
                    if !isScanMode {
                        isScanMode = true          // first tap: go fullscreen
                    } else {
                        scanChat.handleTap(at: point)  // in scan mode: scan object
                    }
                }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    if isScanMode {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: {
                                showCloseConfirmation = true
                            }) {
                                Label("Close", systemImage: "xmark")
                            }
                            .disabled(
                                showCloseConfirmation || showSaveConfirmation
                            )
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: {
                                showSaveConfirmation = true
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

            // Hint while live and waiting for a tap.
            if isScanMode, scanChat.isModelReady, scanChat.phase == .idle,
               !overlaysBlocked {
                VStack {
                    Spacer()
                    Text("Tap an object to meet it!")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
            }

            // Identifying the tapped object.
            if isScanMode, scanChat.phase == .scanning {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Meeting your new friend…")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(20)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
            }

            // Live chat overlay (PRD §4b) once the object is identified.
            if isScanMode, scanChat.phase == .chatting, !overlaysBlocked {
                ChatOverlay(
                    messages: scanChat.vlm.messages,
                    isThinking: scanChat.vlm.isThinking,
                    draft: $scanChat.draft,
                    onSend: scanChat.send
                )
            }

            // Model loading now happens at app launch (ContentView gate), so no
            // loading card here — by the time the camera shows, the VLM is ready.

            if showSaveConfirmation && !showCloseConfirmation {
                SaveConfirmationOverlay(
                    itemName: scanChat.scannedObject?.objectName ?? "Friend",
                    itemImage: Image(systemName: "cup.and.saucer.fill"),
                    onYes: {
                        showSaveConfirmation = false
                        isScanMode = false
                        // taruh logic save disini
                        scanChat.reset()
                    },
                    onNotNow: {
                        showSaveConfirmation = false
                    }
                )
            }

            if !showSaveConfirmation && showCloseConfirmation {
                CloseConfirmationOverlay(
                    itemName: scanChat.scannedObject?.objectName ?? "Your friend",
                    onYes: {
                        showCloseConfirmation = false
                        isScanMode = false
                        scanChat.reset()
                    },
                    onNotNow: {
                        showCloseConfirmation = false
                    }
                )
            }

        }
        .animation(
            .spring(response: 0.35, dampingFraction: 0.85),
            value: showSaveConfirmation
        )
        .animation(.easeInOut(duration: 0.25), value: scanChat.phase)
    }
}

struct SaveConfirmationOverlay: View {
    let itemName: String
    let itemImage: Image
    let onYes: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 24) {

                Text("Save \(itemName) to\nCollection?")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    Button(action: onYes) {
                        Text("Yes")
                            .font(.headline)
                            .foregroundStyle(Color.purple)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .clipShape(Capsule())
                    }

                    Button(action: onNotNow) {
                        Text("Not Now")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .padding(.top, 60)
            .background(
                LinearGradient(
                    colors: [Color.purple.opacity(0.85), Color.purple],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .padding(.horizontal, 24)

            itemImage
                .resizable()
                .scaledToFit()
                .frame(width: 75, height: 75)
                .padding(20)
                .background(Circle().fill(Color.white))
                .overlay(Circle().stroke(Color.white, lineWidth: 4))
                .offset(y: -150)
        }
    }
}

struct CloseConfirmationOverlay: View {
    let itemName: String
    let onYes: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 24) {

                Text("\(itemName) will missing if you close now!")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    Button(action: onYes) {
                        Text("Close")
                            .font(.headline)
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .clipShape(Capsule())
                    }

                    Button(action: onNotNow) {
                        Text("Cancel")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal)
            .padding(.top, 60)
            .background(
                LinearGradient(
                    colors: [Color.red.opacity(0.85), Color.red],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .padding(.horizontal, 24)

            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 75, height: 75)
                .padding(20)
                .offset(y: -135)
                .foregroundColor(Color.white)
        }
    }
}
