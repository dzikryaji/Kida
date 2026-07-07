import RealityKit
import SwiftUI

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: KidaViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let controller = ARFacePlacementController(arView: arView)
        context.coordinator.controller = controller
        viewModel.attachARController(controller)
        controller.startSession()

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.controller?.pauseSession()
    }

    final class Coordinator: NSObject {
        var controller: ARFacePlacementController?
        private weak var viewModel: KidaViewModel?

        init(viewModel: KidaViewModel) {
            self.viewModel = viewModel
        }

        @objc
        @MainActor
        func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let arView = recognizer.view as? ARView else {
                return
            }

            let point = recognizer.location(in: arView)
            controller?.updateTargetPoint(point)
            viewModel?.targetPointDidChange()
        }
    }
}
