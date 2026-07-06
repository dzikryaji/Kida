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

    @FocusState private var isTyping: Bool

    var isFullScreenMode: Bool {
        scanViewModel.isScanning || scanViewModel.placedAnchor != nil
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
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .glassEffect(
                                    .regular.interactive(),
                                    in: .capsule
                                )

                            Button {
                                // action
                                if isTyping {
                                    isTyping.toggle()
                                }
                            } label: {
                                if isTyping {
                                    Image(systemName: "xmark")
                                        .font(
                                            .system(size: 16, weight: .medium)
                                        )
                                        .frame(width: 36, height: 36)
                                } else {
                                    Image(systemName: "microphone.fill")
                                        .font(
                                            .system(size: 16, weight: .medium)
                                        )
                                        .frame(width: 36, height: 36)
                                }
                            }
                            .foregroundStyle(Color(.systemGray))
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

// NOTE on the Preview crash:
// ARKit (ARWorldTrackingConfiguration / session.run) cannot run in Xcode
// Previews or the Simulator — there's no real camera or motion hardware.
// If ARViewContainer unconditionally starts a session in makeUIView, the
// preview process will crash or hang. Guard it, e.g. inside
// ARViewContainer.makeUIView:
//
//     #if targetEnvironment(simulator)
//     // return a placeholder UIView / skip session.run entirely
//     #else
//     guard ARWorldTrackingConfiguration.isSupported else {
//         // show a fallback, don't call session.run
//         return arView
//     }
//     arView.session.run(ARWorldTrackingConfiguration())
//     #endif
//
// Previews should ideally use a mock ScanViewModel/ARViewContainer rather
// than the real AR-backed one. A real device build is otherwise required
// to exercise ScanView.
#Preview {
    let viewModel = ScanViewModel()

    ScanView(scanViewModel: viewModel)
}


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
