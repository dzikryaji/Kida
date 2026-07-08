//
//  CollectionView.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 03/07/26.
//

import SwiftUI
import SwiftData

struct CollectionView: View {
    // Pulled from the environment (set up by .modelContainer in the App file)
    @Environment(\.modelContext) private var modelContext

    // ViewModel is created once using that context
    @State private var viewModel: CollectionViewModel?
    
    var body: some View {
        VStack {
            Text("Collection View")
        }
        .onAppear {
            if viewModel == nil {
                let repository = ScannedItemRepository(modelContext: modelContext)
                viewModel = CollectionViewModel(repository: repository)
            }
        }
    }
        
}

#Preview {
    CollectionView()
}
