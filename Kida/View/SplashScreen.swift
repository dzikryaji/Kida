//
//  SplashScreen.swift
//  Kida
//
//  Created by Imelda Damayanti on 08/07/26.
//

import SwiftUI

struct SplashScreen: View {
    var body: some View {
        Image("Splashscreen")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}

#Preview {
    SplashScreen()
}
