//
//  ScanChatModel.swift
//  kida
//
//  View model for the live scan → chat flow (PRD §5). Owns the VLM, the current
//  ScannedObject, and the phase state machine:
//
//      idle → scanning → chatting        (per object)
//
//  Wiring: ScanView hands taps here; we capture a frame, identify the object,
//  and open the chat. The teammate's face layer can read `scannedObject`,
//  `lastTapPoint`, and `vlm.isThinking` (PRD §10 handoff).
//

import SwiftUI
import RealityKit

@MainActor
@Observable
final class ScanChatModel {

    enum Phase {
        case idle       // live camera, waiting for a tap
        case scanning   // frame captured, VLM identifying
        case chatting   // object introduced, chat active
    }

    let vlm = VLMChatModel()
    var phase: Phase = .idle
    var scannedObject: ScannedObject?
    var draft = ""

    /// Where the user tapped (ARView coords) — part of the face-layer handoff.
    var lastTapPoint: CGPoint?

    /// Set by ARViewContainer.onARViewReady. Weak: the AR session owns the view.
    @ObservationIgnored weak var arView: ARView?

    var isModelReady: Bool {
        if case .ready = vlm.loadState { return true }
        return false
    }

    func loadModelIfNeeded() async {
        await vlm.loadModel()
    }

    // MARK: - Flow

    /// Tap in scan mode = "this object!". Only accepted while idle — once a scan
    /// starts (or a chat is running) taps are locked, so the user can't switch
    /// to another object mid-conversation. `reset()` unlocks.
    func handleTap(at point: CGPoint) {
        print("[kida] tap at \(point) — modelReady=\(isModelReady) phase=\(phase) arView=\(arView != nil)")
        guard isModelReady, phase == .idle, let arView else { return }

        lastTapPoint = point
        phase = .scanning

        Task {
            if let (object, image) = await vlm.scanObject(at: point, in: arView) {
                print("[kida] scanned: \(object.objectName) / \(object.personality) / \(object.estimatedDistance)")
                scannedObject = object
                phase = .chatting                       // overlay appears now;
                await vlm.startChat(for: object, image: image) // greeting streams in
            } else {
                print("[kida] scan FAILED (capture or VLM)")
                phase = .idle                           // capture/VLM failed; try again
            }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !vlm.isThinking else { return }
        draft = ""
        Task { await vlm.ask(text) }
    }

    /// Back to the live camera (after save or close).
    func reset() {
        phase = .idle
        scannedObject = nil
        lastTapPoint = nil
        draft = ""
        vlm.messages = []
    }
}
