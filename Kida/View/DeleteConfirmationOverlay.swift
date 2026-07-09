//
//  DeleteConfirmationOverlay.swift
//  Kida
//
//  Created by Imelda Damayanti on 09/07/26.
//

import SwiftUI

struct DeleteConfirmationOverlay: View {
    let itemName: String
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 24) {

                Text("Are you sure want to\ndelete \(itemName)?")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    Button(action: onDelete) {
                        Text("Delete")
                            .font(.headline)
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .clipShape(Capsule())
                    }

                    Button(action: onCancel) {
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

            Image(systemName: "trash.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 65, height: 75)
                .padding(20)
                .offset(y: -135)
                .foregroundColor(Color.white)
        }
    }
}

#Preview {
    DeleteConfirmationOverlay(
        itemName: "Mug",
        onDelete: {},
        onCancel: {}
    )
}
