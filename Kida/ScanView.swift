//
//  ScanView.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 03/07/26.
//

import SwiftUI

struct ScanView: View {
    @Binding var isScanMode: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                CameraView(isScanMode: $isScanMode)
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
            ScanView(isScanMode: $isScanMode)
        }
    }
    return PreviewWrapper()
}

struct CameraView: View {
    @Binding var isScanMode: Bool
    @State private var showSaveConfirmation = false
    @State private var showCloseConfirmation = false

    var body: some View {
        ZStack {
            ARViewContainer()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    if !isScanMode {
                        isScanMode = true
                    }
                }
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

            if showSaveConfirmation && !showCloseConfirmation {
                SaveConfirmationOverlay(
                    itemName: "Mug",
                    itemImage: Image(systemName: "cup.and.saucer.fill"),
                    onYes: {
                        showSaveConfirmation = false
                        isScanMode = false
                        // taruh logic save disini
                    },
                    onNotNow: {
                        showSaveConfirmation = false
                    }
                )
            }

            if !showSaveConfirmation && showCloseConfirmation {
                CloseConfirmationOverlay(
                    itemName: "Mug",
                    onYes: {
                        showCloseConfirmation = false
                        isScanMode = false
                        // taruh logic save disini
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
