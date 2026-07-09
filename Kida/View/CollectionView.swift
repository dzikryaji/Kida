//
//  CollectionView.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 03/07/26.
//

import SwiftUI
import SwiftData
// struct CollectedItem: Identifiable{
//     let id = UUID()
//     var label: String
//     var capturedDate: Date
//     var image: UIImage?
// }

// let sampleItems: [CollectedItem] = (0..<6).map { _ in
//     CollectedItem(label: "MUG", capturedDate: .now, image: nil)
// }

struct CollectionView: View {
    @Binding var isDetailPresented: Bool
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: CollectionViewModel?
    @State private var itemToDelete: ScannedItem?
    
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
                
                
                if viewModel?.items.isEmpty ?? true {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 48))
                            .foregroundStyle(Color(red: 0.31, green: 0.25, blue: 0.85).opacity(0.5))

                        Text("Your collection is empty")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.black.opacity(0.7))

                        Text("Point your camera at an object\nto discover its story.")
                            .font(.system(size: 14))
                            .foregroundStyle(.black.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(viewModel?.items ?? []) { item in
                            let uiImage = viewModel?.imageData(for: item).flatMap(UIImage.init)
                            
                            NavigationLink {
                                CollectionDetail(item: item, image: uiImage)
                                    .onAppear { isDetailPresented = true }
                                    .onDisappear { isDetailPresented = false }
                            } label: {
                                CollectionCard(item: item, image: uiImage)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        itemToDelete = item
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color(red: 0.93, green: 0.92, blue: 0.98)
                    .ignoresSafeArea()
            )
            
            .onAppear {
                //                guard viewModel == nil else { return }   // build once
                //
                //                    .onAppear {
                if viewModel == nil {
                    let repository = ScannedItemRepository(modelContext: modelContext)
                    viewModel = CollectionViewModel(repository: repository)
                } else {
                    viewModel?.fetchItems()   // re-entering tab → pick up newly scanned items
                }
                //                    }
                // let repository = ScannedItemRepository(modelContext: modelContext)
                // let vm = CollectionViewModel(repository: repository)
                // viewModel = vm
                
                // // temporary seed — delete when scan flow saves real items
                // if vm.items.isEmpty {
                //     vm.addItem(
                //         imageData: UIImage(named: "mug1")?.jpegData(compressionQuality: 0.8),
                //         itemDescription: "\"Hi! I'm Mug. I'm here to make your drinks extra special...\"",
                //         objectName: "Mug"
                //     )
                //     vm.addItem(
                //         imageData: UIImage(named: "mug2")?.jpegData(compressionQuality: 0.8),
                //         itemDescription: "\"Hi! I'm Mug Two.\"",
                //         objectName: "Mug 2",
                //         date: .now.addingTimeInterval(-86400)   // yesterday, tests sort
                //     )
            }
            .overlay {
                if let item = itemToDelete {
                    DeleteConfirmationOverlay(
                        itemName: item.objectName,
                        onDelete: {
                            viewModel?.deleteItem(item)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                itemToDelete = nil
                            }
                        },
                        onCancel: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                itemToDelete = nil
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }

}

#Preview {
    CollectionView(isDetailPresented: .constant(false))
        .modelContainer(for: ScannedItem.self, inMemory: true)
}
// import SwiftData

// struct CollectionView: View {
//     // Pulled from the environment (set up by .modelContainer in the App file)
//     @Environment(\.modelContext) private var modelContext

//     // ViewModel is created once using that context
//     @State private var viewModel: CollectionViewModel?

//     var body: some View {
//         VStack {
//             Text("Collection View")
//         }
//         .onAppear {
//             if viewModel == nil {
//                 let repository = ScannedItemRepository(modelContext: modelContext)
//                 viewModel = CollectionViewModel(repository: repository)
//             }
//         }
//     }

// }

// #Preview {
//     CollectionView(isDetailPresented: .constant(false))
// }
