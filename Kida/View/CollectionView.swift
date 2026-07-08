//
//  CollectionView.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 03/07/26.
//

import SwiftUI
struct CollectedItem: Identifiable{
    let id = UUID()
    var label: String
    var capturedDate: Date
    var image: UIImage?
}

let sampleItems: [CollectedItem] = (0..<6).map { _ in
    CollectedItem(label: "MUG", capturedDate: .now, image: nil)
}


struct CollectionView: View {
    @Binding var isDetailPresented: Bool

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
        VStack {
            HStack {
                Text("Collection")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.bottom, 20)

                Spacer()

                Button {
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.black)
                        .padding(14)
                        .background(.white)
                        .clipShape(Circle())
                }

                Button {
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.black)
                        .padding(14)
                        .background(.white)
                        .clipShape(Circle())
                }
            }
            .padding()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(0..<6) { _ in
                        NavigationLink {
                            CollectionDetail(
                                title: "MUG",
                                date: "July 02, 2026",
                                imageName: "mug1",
                                summary: "\"Hi! I'm Mug. I'm here to make your drinks extra special. Every morning, you fill me up with something warm, and together we start the day. I love when you take a break with me and enjoy your favorite drink.\""
                            )
                            .onAppear { isDetailPresented = true }
                            .onDisappear { isDetailPresented = false }
                        } label: {
                            CollectionCard(
                                title: "MUG",
                                date: "July 02, 2026",
                                imageName: "mug1"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(red: 0.93, green: 0.92, blue: 0.98)
                .ignoresSafeArea()
        )
        }
    }
}

#Preview {
    CollectionView(isDetailPresented: .constant(false))
}
