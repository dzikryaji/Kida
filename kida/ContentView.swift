//
//  ContentView.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 01/07/26.
//

import SwiftUI

enum AppTab: String, CaseIterable {
    case scan
    case collection

    var title: String {
        switch self {
        case .scan: "Scan"
        case .collection: "Collection"
        }
    }

    var icon: String {
        switch self {
        case .scan: "camera.macro.circle.fill"
        case .collection: "square.stack.3d.up.fill"
        }
    }
}

struct ContentView: View {
    @State private var selection: AppTab = .collection
    @State private var isScanMode: Bool = false

    var body: some View {
        TabView(selection: $selection) {
            Tab(
                AppTab.scan.title,
                systemImage: AppTab.scan.icon,
                value: .scan
            ) {
                ScanView(isScanMode: $isScanMode)
                    // hide the tab bar only while Scan is selected
                    .toolbar(isScanMode ? .hidden : .visible, for: .tabBar)
            }

            Tab(
                AppTab.collection.title,
                systemImage: AppTab.collection.icon,
                value: .collection
            ) {
                CollectionView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isScanMode)
    }
}

#Preview {
    ContentView()
}
