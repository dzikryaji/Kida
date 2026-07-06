//
//  SaveConfirmationOverlay.swift
//  Kida
//
//  Created by Dzikry Aji Santoso on 06/07/26.
//

import SwiftUI

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
