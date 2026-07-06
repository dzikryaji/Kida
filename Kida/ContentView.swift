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
    @StateObject private var scanViewModel = ScanViewModel()

    private var isFullScreenMode: Bool {
        scanViewModel.isScanning || scanViewModel.placedAnchor != nil
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(
                AppTab.scan.title,
                systemImage: AppTab.scan.icon,
                value: .scan
            ) {
                ScanView(scanViewModel: scanViewModel)
                    // hide the tab bar only while Scan is selected
                    .toolbar(isFullScreenMode ? .hidden : .visible, for: .tabBar)
            }

            Tab(
                AppTab.collection.title,
                systemImage: AppTab.collection.icon,
                value: .collection
            ) {
                CollectionView()
            }
        }
        // The actual driver of the animation is `withAnimation` wrapping the
        // `isScanning` / `placedAnchor` mutations inside ScanViewModel — that's
        // the single source of truth both this view and ScanView read from.
        // This modifier just makes sure the tab-bar visibility toggle (the one
        // piece of UI ContentView itself owns) animates in step with that.
        .animation(.easeInOut(duration: 0.3), value: isFullScreenMode)
    }
}

#Preview {
    ContentView()
}
