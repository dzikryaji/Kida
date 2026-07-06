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
                        .padding(.top, isScanMode ? 0 : geo.safeAreaInsets.top + 64)
                        .padding(.bottom, isScanMode ? 0 : geo.safeAreaInsets.bottom + 100)
                }
                .ignoresSafeArea(.all)

                if showSaveConfirmation && !showCloseConfirmation {
                    SaveConfirmationOverlay(
                        itemName: "Mug",
                        itemImage: Image(systemName: "cup.and.saucer.fill"),
                        onYes: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showSaveConfirmation = false
                            }
                            withAnimation(.easeInOut(duration: 0.35)) {
                                isScanMode = false
                            }
                            // taruh logic save disini
                        },
                        onNotNow: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
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
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showCloseConfirmation = false
                            }
                            withAnimation(.easeInOut(duration: 0.35)) {
                                isScanMode = false
                            }
                            // taruh logic save disini
                        },
                        onNotNow: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showCloseConfirmation = false
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .toolbar {
                if isScanMode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
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
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
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
    struct PreviewWrapper: View {
        @State var isScanMode = false
        var body: some View {
            ScanView(isScanMode: $isScanMode)
        }
    }
    return PreviewWrapper()
}
