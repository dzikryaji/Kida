//
//  RootView.swift
//  Kida
//
//  Created by Imelda Damayanti on 08/07/26.
//

import SwiftUI

enum AppStage {
    case splash
    case onboarding
    case main
}

struct RootView: View {
    @State private var stage: AppStage = .splash
    
    var body: some View {
        switch stage {
        case .splash:
            SplashScreen()
                .task {
                    try? await Task.sleep(for: .seconds(0.5))   // splash show 2 sec
                    withAnimation { stage = .onboarding }
                }
        case .onboarding:
            OnBoarding(onGetStarted: {
                withAnimation { stage = .main }
            })
        case .main:
            ContentView()
        }
    }
}

#Preview {
    RootView()
}
