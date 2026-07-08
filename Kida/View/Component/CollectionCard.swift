//
//  CollectionCard.swift
//  Kida
//
//  Created by Imelda Damayanti on 08/07/26.
//
import SwiftUI

struct CollectionCard: View {
    let title: String
    let date: String
    let imageName: String
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(imageName)
                .resizable()
                .scaledToFill()
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
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black)
                
                Text(date)
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
        title: "MUG",
        date: "July 02, 2026",
        imageName: "mug2"
    )
}
