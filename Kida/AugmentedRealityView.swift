////
////  ARView.swift
////  DummyKida
////
//
//import SwiftUI
//
//struct AugmentedRealityView: View {
//
//    @StateObject private var viewModel = ScanViewModel()
//
//    var body: some View {
//        NavigationStack {
//            ZStack {
//                ARViewContainer(viewModel: viewModel)
//                    .edgesIgnoringSafeArea(.all)
//
//                if viewModel.isScanning {
//                    ScanningOverlay()
//                        .transition(.opacity)
//                }
//            }
//            .animation(.easeInOut(duration: 0.2), value: viewModel.isScanning)
//            .toolbar {
//                ToolbarItem(placement: .navigationBarLeading) {
//                    Button(action: {
//                        viewModel.replaceBubbleLabel()
//                    }) {
//                        Image(systemName: "arrow.2.squarepath")
//                    }
//                    .disabled(viewModel.placedAnchor == nil)
//                }
//
//                ToolbarItem(placement: .navigationBarTrailing) {
//                    Button(action: {
//                        viewModel.removePlacedObject()
//                    }) {
//                        Image(systemName: "trash")
//                    }
//                    .disabled(viewModel.placedAnchor == nil)
//                }
//            }
//        }
//    }
//}
//
//
//#Preview {
//    AugmentedRealityView()
//}
