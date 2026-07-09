//
//  CollectionDetail.swift
//  Kida
//
//  Created by Imelda Damayanti on 08/07/26.
//

import SwiftUI

struct CollectionDetail: View {
    @Environment(\.dismiss) private var dismiss

    let item: ScannedItem
    let image: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 48, height: 48)
                        .background(.white)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                }

                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color(red: 0.98, green: 0.95, blue: 0.87)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundStyle(.gray.opacity(0.5))
                            )
                    }
                }
                .frame(height: 360)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .shadow(color: .black.opacity(0.15), radius: 15, y: 8)

                Text(item.objectName)
                    .font(.system(size: 34, weight: .bold))

                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(item.date.formatted(date: .long, time: .shortened))
                        .font(.system(size: 14))
                }

                Text("Summary")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(red: 0.31, green: 0.25, blue: 0.85))

                Text(item.itemDescription)
                    .padding()
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.99, green: 0.96, blue: 0.87))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.93, green: 0.92, blue: 0.98).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview {
    CollectionDetail(
        item: ScannedItem(
            itemDescription: "Hi! I'm Mug. I'm here to make your drinks extra special.",
            objectName: "Mug"
        ),
        image: nil
    )
}
