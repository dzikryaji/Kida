//
//  ARViewContainer.swift
//  kida
//
//  Created by Dzikry Aji Santoso on 03/07/26.
//

import SwiftUI
import RealityKit
import ARKit

struct ARViewContainer: UIViewRepresentable {
    
    @ObservedObject var scanViewModel: ScanViewModel
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical]

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        arView.session.run(config)

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        arView.addGestureRecognizer(tapGesture)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // empty
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scanViewModel: scanViewModel)
    }
    
    class Coordinator {
        private let scanViewModel: ScanViewModel
        
        init(scanViewModel: ScanViewModel) {
            self.scanViewModel = scanViewModel
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView = recognizer.view as? ARView else { return }
            let tapLocation = recognizer.location(in: arView)
            scanViewModel.placeObject(at: tapLocation, in: arView)
        }
    }
}
