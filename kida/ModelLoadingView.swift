//
//  ModelLoadingView.swift
//  kida
//
//  First-launch UI while SmolVLM downloads / loads. Ported from the VLM
//  prototype's loading + error screens. Shown until loadState == .ready.
//

import SwiftUI

struct ModelLoadingView: View {
    let state: VLMChatModel.LoadState
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .failed(let message):
            errorScreen(message)
        default:
            loadingScreen
        }
    }

    private var loadingScreen: some View {
        VStack(spacing: 16) {
            Text("🧠").font(.system(size: 60))
            Text("Getting my brain ready…")
                .font(.title3.bold())

            if case .downloading(let fraction) = state, fraction > 0 {
                ProgressView(value: fraction)
                    .tint(.purple)
                    .frame(maxWidth: 240)
                Text("\(Int(fraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("First time only — the model is downloading.\nKeep the app open!")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                    .tint(.purple)
            }
        }
        .padding()
    }

    private func errorScreen(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text("😵").font(.system(size: 60))
            Text("Something went wrong")
                .font(.title3.bold())
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .tint(.purple)
        }
        .padding()
    }
}

#Preview("Downloading") {
    ModelLoadingView(state: .downloading(0.42), onRetry: {})
}

#Preview("Failed") {
    ModelLoadingView(state: .failed("Network unreachable"), onRetry: {})
}
