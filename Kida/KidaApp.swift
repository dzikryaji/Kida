//
//  kidaApp.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 01/07/26.
//

import SwiftUI
import SwiftData

@main
struct KidaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
        }
        .modelContainer(for: ScannedItem.self)
    }
}
