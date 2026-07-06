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

    // Owned at app level so SmolVLM loads at launch, not when the camera opens.
    @State private var scanChat = ScanChatModel()

    var body: some View {
        Group {
            if scanChat.isModelReady {
                mainTabs
            } else {
                // Launch gate: "Getting my brain ready…" before the app UI.
                ModelLoadingView(state: scanChat.vlm.loadState) {
                    Task { await scanChat.vlm.loadModel() }
                }
            }
        }
        .task { await scanChat.loadModelIfNeeded() }
        .animation(.easeInOut(duration: 0.3), value: scanChat.isModelReady)
    }

    private var mainTabs: some View {
        TabView(selection: $selection) {
            Tab(
                AppTab.scan.title,
                systemImage: AppTab.scan.icon,
                value: .scan
            ) {
                ScanView(isScanMode: $isScanMode, scanChat: scanChat)
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
