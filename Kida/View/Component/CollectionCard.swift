//
//  CollectionCard.swift
//  Kida
//
//  Created by Imelda Damayanti on 08/07/26.
//
import SwiftUI

struct CollectionCard: View {
    let item: ScannedItem
    // Pixels resolved by caller (CollectionViewModel.imageData) —
    // model only stores a filename.
    let image: UIImage?
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                            if let image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                // placeholder when no photo on disk
                                Color(red: 0.98, green: 0.95, blue: 0.87)
                                    .overlay(
                                        Image(systemName: "photo")
                                            .font(.largeTitle)
                                            .foregroundStyle(.gray.opacity(0.5))
                                    )
                            }
                        }
                
                .frame(width: 170, height: 190)
                .clipped()
            
            LinearGradient(
                colors: [
                    .clear,
                    Color(red: 0.98, green: 0.95, blue: 0.87)                ],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 180)
            
            VStack(alignment: .leading) {
                Text(item.objectName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black)

                Text(item.date.formatted(date: .long, time: .omitted))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black.opacity(0.8))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .frame(width: 166, height: 175)
        .background(Color(red: 0.98, green: 0.95, blue: 0.87))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}

#Preview {
    CollectionCard(
        item: ScannedItem(itemDescription: "test", objectName: "MUG"),
        image: UIImage(named: "mug2")
    )
}
