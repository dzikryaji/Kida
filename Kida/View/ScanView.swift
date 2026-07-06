//
//  ScanView.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 03/07/26.
//

import SwiftUI

struct ScanView: View {
    @Binding var isScanMode: Bool
    @State private var showSaveConfirmation = false
    @State private var showCloseConfirmation = false
    @State private var messageText = ""
    @FocusState private var isTyping: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                GeometryReader { geo in
                    ARViewContainer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture {
                            if !isScanMode {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    isScanMode = true
                                }
                            }

                        }
                        .cornerRadius(isScanMode ? 0 : 34)
                        .padding(.horizontal, isScanMode ? 0 : 16)
                        .padding(
                            .top,
                            isScanMode ? 0 : geo.safeAreaInsets.top + 64
                        )
                        .padding(
                            .bottom,
                            isScanMode ? 0 : geo.safeAreaInsets.bottom + 100
                        )
                }
                .ignoresSafeArea(.all)

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
                            withAnimation(.easeInOut(duration: 0.35)) {
                                isScanMode = false
                            }
                            // taruh logic save disini
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
                            withAnimation(.easeInOut(duration: 0.35)) {
                                isScanMode = false
                            }
                            // taruh logic save disini
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

                if isScanMode {
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
            }
            .toolbar {
                if isScanMode {
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

                    //                    ToolbarItem(placement: .bottomBar) {
                    //                        TextField("Text me", text: $messageText)
                    //                            .focused($isTyping)
                    //                            .textFieldStyle(.plain)
                    //                            .background(Color.clear)
                    //                            .padding(.horizontal, 10)
                    //                            .onChange(of: isTyping) { newValue in
                    //                                print("isTyping berubah jadi: \(newValue)")
                    //                            }
                    //                    }
                    //
                    //                    ToolbarItem(placement: .bottomBar) {
                    //                        Button {
                    //                            // action
                    //                        } label: {
                    //                            Image(systemName: "microphone.fill")
                    //                        }
                    //                        .opacity(isTyping ? 0 : 1)
                    //                        .disabled(isTyping)
                    //                        .allowsHitTesting(!isTyping)
                    //                        .animation(.easeInOut(duration: 0.2), value: isTyping)
                    //                    }
                }

            }
        }
    }
}
#Preview {
    struct PreviewWrapper: View {
        @State var isScanMode = false
        var body: some View {
            ScanView(isScanMode: $isScanMode)
        }
    }
    return PreviewWrapper()
}
