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
        context.coordinator.tapGesture = tapGesture
        arView.addGestureRecognizer(tapGesture)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Ignore taps while a scan is already placed or a segmentation is
        // in flight, so a second tap can't race the first one.
        let busy = scanViewModel.isScanning || scanViewModel.placedAnchor != nil
        context.coordinator.tapGesture?.isEnabled = !busy
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scanViewModel: scanViewModel)
    }
    
    class Coordinator {
        private let scanViewModel: ScanViewModel
        weak var tapGesture: UITapGestureRecognizer?
        
        init(scanViewModel: ScanViewModel) {
            self.scanViewModel = scanViewModel
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView = recognizer.view as? ARView else { return }

            // We need the camera frame at the moment of the tap so SAM can
            // segment the object the child actually pointed at.
            guard let frame = arView.session.currentFrame else {
                print("No current AR frame available, skipping segmentation")
                return
            }

            let tapLocation = recognizer.location(in: arView)

            scanViewModel.placeObject(
                at: tapLocation,
                pixelBuffer: frame.capturedImage,
                viewSize: arView.bounds.size,
                in: arView
            )
        }
    }
}
