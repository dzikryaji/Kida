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

    var onARViewReady: ((ARView) -> Void)? = nil
    var onTap: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()

        config.planeDetection = [.horizontal, .vertical]

        // Mesh reconstruction DISABLED for now: SmolVLM + mesh together exceed
        // the iOS memory limit (app killed, exit code 9). Re-enable once the
        // team decides how to balance RAM between AR and the VLM.
        // if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
        //     config.sceneReconstruction = .mesh
        // }

        arView.session.run(config)

        // Report taps without swallowing touches, so any SwiftUI gesture on the
        // container still fires (cancelsTouchesInView = false).
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        arView.addGestureRecognizer(tap)

        context.coordinator.arView = arView
        onARViewReady?(arView)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Keep the coordinator's closure in sync with the latest view state.
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    final class Coordinator: NSObject {
        weak var arView: ARView?
        var onTap: ((CGPoint) -> Void)?

        init(onTap: ((CGPoint) -> Void)?) {
            self.onTap = onTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView else { return }
            onTap?(gesture.location(in: arView))
        }
    }
}
