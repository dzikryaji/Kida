//
//  CollectionCard.swift
//  Kida
//
//  Created by Imelda Damayanti on 08/07/26.
//

import SwiftUI

struct CollectionCard: View {
    let item: ScannedItem
    let rawImage: UIImage?
    let stickerImage: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 1.0, green: 0.97, blue: 0.89))
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.white.opacity(0.72))
                        .blur(radius: 26)
                        .frame(width: 132, height: 132)
                        .offset(x: 18, y: -24)
                }

            CollectionStickerPoster(
                stickerImage: stickerImage,
                fallbackImage: rawImage,
                cornerRadius: 28,
                imagePadding: 16
            )

            LinearGradient(
                colors: [
                    .clear,
                    Color(red: 1.0, green: 0.97, blue: 0.89).opacity(0.94)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 112)
            .frame(maxHeight: .infinity, alignment: .bottom)

            VStack(alignment: .leading, spacing: 8) {
                Text(item.objectName.uppercased())
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(Self.dateFormatter.string(from: item.date))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 13, x: 0, y: 9)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM dd, yyyy"
        return formatter
    }()
}

struct CollectionStickerPoster: View {
    let stickerImage: UIImage?
    let fallbackImage: UIImage?
    var cornerRadius: CGFloat = 28
    var imagePadding: CGFloat = 18

    var body: some View {
        ZStack {
            Color.clear

            if let stickerImage {
                Image(uiImage: stickerImage)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, imagePadding)
                    .padding(.top, imagePadding * 0.55)
                    .padding(.bottom, 58)
                    .shadow(color: .black.opacity(0.13), radius: 8, y: 4)
            } else if let fallbackImage {
                Image(uiImage: fallbackImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(Color.white.opacity(0.28))
            } else {
                placeholderView
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholderView: some View {
        Color.clear
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.18))
                    .padding(.bottom, 42)
            }
    }
}

struct CollectionRevealSlider: View {
    let rawImage: UIImage?
    let stickerImage: UIImage?
    @Binding var stickerCoverage: CGFloat
    var cornerRadius: CGFloat = 28
    var stickerPadding: CGFloat = 34

    private var hasBothImages: Bool {
        rawImage != nil && stickerImage != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            let coverage = min(max(stickerCoverage, 0), 1)
            let handleX = width * coverage

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    if hasBothImages {
                        rawImageView
                            .frame(width: width, height: height)

                        stickerStage
                            .frame(width: width, height: height)
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: handleX, height: height)
                            }
                    } else if stickerImage != nil {
                        stickerStage
                    } else if rawImage != nil {
                        rawImageView
                    } else {
                        placeholderView
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                if hasBothImages {
                    divider(at: handleX, height: height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        stickerCoverage = min(max(value.location.x / width, 0), 1)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sticker and photo comparison")
            .accessibilityValue("\(Int(coverage * 100)) percent sticker visible")
        }
    }

    @ViewBuilder
    private var stickerImageView: some View {
        if let stickerImage {
            Image(uiImage: stickerImage)
                .resizable()
                .scaledToFit()
                .padding(stickerPadding)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
        } else {
            placeholderView
        }
    }

    private var stickerStage: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 1.0, green: 0.98, blue: 0.93),
                    Color(red: 0.97, green: 0.95, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            stickerImageView
        }
    }

    @ViewBuilder
    private var rawImageView: some View {
        if let rawImage {
            Image(uiImage: rawImage)
                .resizable()
                .scaledToFill()
                .overlay(Color.black.opacity(0.04))
                .clipped()
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        Color(red: 1.0, green: 0.97, blue: 0.89)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.18))
            }
    }

    @ViewBuilder
    private func divider(at x: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.94))
            .frame(width: 2, height: height)
            .shadow(color: .black.opacity(0.28), radius: 7, x: 0, y: 0)
            .offset(x: x - 1)

        Circle()
            .fill(.ultraThinMaterial)
            .overlay {
                HStack(spacing: 3) {
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(270))

                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 1.5, height: 16)

                    Image(systemName: "triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(90))
                }
                .foregroundStyle(Color.black.opacity(0.78))
            }
            .frame(width: 38, height: 38)
            .shadow(color: .black.opacity(0.24), radius: 9, y: 4)
            .offset(x: x - 19, y: height * 0.5 - 19)
    }
}

#Preview {
    CollectionCard(
        item: ScannedItem(itemDescription: "test", objectName: "Mug"),
        rawImage: nil,
        stickerImage: nil
    )
}
