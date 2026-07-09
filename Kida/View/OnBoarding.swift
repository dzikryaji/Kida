//
//  OnBoarding.swift
//  Kida
//
//  Created by Imelda Damayanti on 08/07/26.
//

import SwiftUI

struct OnBoarding: View {
    var onGetStarted: () -> Void
    var body: some View {
        VStack(alignment: .leading){
            
            Spacer()
            Text("Point your camera at anything.")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.indigo.opacity(0.6))
            
            Text("It reacts, remembers, and stays in your collection.")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color(red: 0x22/255, green: 0x0F/255, blue: 0x6B/255))
            
            
            Spacer()
            
            Button{
                onGetStarted()
            } label: {
                Text("Get Started")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.48, green: 0.40, blue: 0.89))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity)
            
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(red: 0.93, green: 0.92, blue: 0.98)
            .ignoresSafeArea())
        
    }
    
}

#Preview {
    
    OnBoarding(onGetStarted: {
        print("Get Started tapped")
    })
    
}
