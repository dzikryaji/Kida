import RealityKit
import UIKit

@MainActor
final class ObjectFaceEntity: Entity {
    private let leftEyeRim: ModelEntity
    private let rightEyeRim: ModelEntity
    private let leftEye: ModelEntity
    private let rightEye: ModelEntity
    private let leftPupil: ModelEntity
    private let rightPupil: ModelEntity
    private let leftBrow: ModelEntity
    private let rightBrow: ModelEntity
    private let mouthBeads: [ModelEntity]
    private var talkingTask: Task<Void, Never>?
    private var restingShape: MouthShape = .smile

    required convenience init() {
        self.init(style: .standard)
    }

    init(style: FaceVisualStyle) {
        let rimMaterial = SimpleMaterial(color: style.eyeRimColor, isMetallic: false)
        let eyeMaterial = SimpleMaterial(color: style.eyeColor, isMetallic: false)
        let pupilMaterial = SimpleMaterial(color: style.pupilColor, isMetallic: false)
        let browMaterial = SimpleMaterial(color: style.browColor, isMetallic: false)
        let mouthMaterial = SimpleMaterial(color: style.mouthColor, isMetallic: false)

        leftEyeRim = ModelEntity(mesh: .generateSphere(radius: 0.039), materials: [rimMaterial])
        rightEyeRim = ModelEntity(mesh: .generateSphere(radius: 0.039), materials: [rimMaterial])
        leftEye = ModelEntity(mesh: .generateSphere(radius: 0.032), materials: [eyeMaterial])
        rightEye = ModelEntity(mesh: .generateSphere(radius: 0.032), materials: [eyeMaterial])
        leftPupil = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [pupilMaterial])
        rightPupil = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [pupilMaterial])
        leftBrow = ModelEntity(mesh: .generateBox(width: 0.075, height: 0.012, depth: 0.014), materials: [browMaterial])
        rightBrow = ModelEntity(mesh: .generateBox(width: 0.075, height: 0.012, depth: 0.014), materials: [browMaterial])
        mouthBeads = (0..<9).map { _ in
            ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [mouthMaterial])
        }

        super.init()
        buildFace()
        apply(emotion: .happy, animated: false)
    }

    deinit {
        talkingTask?.cancel()
    }

    func apply(emotion: Emotion, animated: Bool) {
        stopTalking(restingEmotion: emotion)

        let preset = ExpressionPreset(emotion: emotion)
        restingShape = preset.mouthShape

        animate(leftEyeRim, to: Transform(scale: preset.eyeScale, translation: [-0.045, 0.035, 0.006]), duration: animated ? 0.25 : 0)
        animate(rightEyeRim, to: Transform(scale: preset.eyeScale, translation: [0.045, 0.035, 0.006]), duration: animated ? 0.25 : 0)
        animate(leftEye, to: Transform(scale: preset.eyeScale, translation: [-0.045, 0.035, -0.004]), duration: animated ? 0.25 : 0)
        animate(rightEye, to: Transform(scale: preset.eyeScale, translation: [0.045, 0.035, -0.004]), duration: animated ? 0.25 : 0)
        animate(leftPupil, to: Transform(scale: .one, translation: [-0.045 + preset.pupilOffset.x, 0.035 + preset.pupilOffset.y, -0.028]), duration: animated ? 0.22 : 0)
        animate(rightPupil, to: Transform(scale: .one, translation: [0.045 + preset.pupilOffset.x, 0.035 + preset.pupilOffset.y, -0.028]), duration: animated ? 0.22 : 0)

        let leftRotation = simd_quatf(angle: preset.leftBrowAngle, axis: [0, 0, 1])
        let rightRotation = simd_quatf(angle: preset.rightBrowAngle, axis: [0, 0, 1])
        animate(leftBrow, to: Transform(scale: .one, rotation: leftRotation, translation: [-0.045, preset.browY, 0]), duration: animated ? 0.25 : 0)
        animate(rightBrow, to: Transform(scale: .one, rotation: rightRotation, translation: [0.045, preset.browY, 0]), duration: animated ? 0.25 : 0)

        setMouth(preset.mouthShape, animated: animated, amplitude: preset.mouthAmplitude)
    }

    func blinkThenApply(emotion: Emotion) {
        talkingTask?.cancel()
        let blinkScale = SIMD3<Float>(1.0, 0.12, 1.0)
        animate(leftEyeRim, to: Transform(scale: blinkScale, translation: [-0.045, 0.035, 0.006]), duration: 0.08)
        animate(rightEyeRim, to: Transform(scale: blinkScale, translation: [0.045, 0.035, 0.006]), duration: 0.08)
        animate(leftEye, to: Transform(scale: blinkScale, translation: [-0.045, 0.035, -0.004]), duration: 0.08)
        animate(rightEye, to: Transform(scale: blinkScale, translation: [0.045, 0.035, -0.004]), duration: 0.08)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000)
            self?.apply(emotion: emotion, animated: true)
        }
    }

    func startTalking(emotion: Emotion) {
        talkingTask?.cancel()
        let preset = ExpressionPreset(emotion: emotion)
        let sequence: [MouthShape] = preset.mouthAmplitude > 1.1
            ? [.closed, .smallOpen, .wideOpen, .open, .smallOpen]
            : [.closed, .smallOpen, .open, .smallOpen]

        talkingTask = Task { @MainActor [weak self] in
            var index = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.setMouth(sequence[index % sequence.count], animated: true, amplitude: preset.mouthAmplitude)
                index += 1
                try? await Task.sleep(nanoseconds: 145_000_000)
            }
        }
    }

    func speakWord(_ word: String, emotion: Emotion) {
        talkingTask?.cancel()
        let preset = ExpressionPreset(emotion: emotion)
        let shape = mouthShape(for: word, preset: preset)

        setMouth(shape, animated: true, amplitude: preset.mouthAmplitude)

        talkingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 95_000_000)
            guard let self, !Task.isCancelled else {
                return
            }

            self.setMouth(.smallOpen, animated: true, amplitude: preset.mouthAmplitude * 0.82)

            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else {
                return
            }

            let restingShape: MouthShape = preset.mouthShape == .smile ? .smile : .closed
            self.setMouth(restingShape, animated: true, amplitude: preset.mouthAmplitude)
        }
    }

    func stopTalking(restingEmotion: Emotion) {
        talkingTask?.cancel()
        talkingTask = nil
        let preset = ExpressionPreset(emotion: restingEmotion)
        restingShape = preset.mouthShape
        setMouth(restingShape, animated: true, amplitude: preset.mouthAmplitude)
    }

    private func buildFace() {
        addChild(leftEyeRim)
        addChild(rightEyeRim)
        addChild(leftEye)
        addChild(rightEye)
        addChild(leftPupil)
        addChild(rightPupil)
        addChild(leftBrow)
        addChild(rightBrow)
        mouthBeads.forEach { addChild($0) }
    }

    private func setMouth(_ shape: MouthShape, animated: Bool, amplitude: Float) {
        let positions = MouthLayout.positions(for: shape, amplitude: amplitude)
        for index in mouthBeads.indices {
            let point = positions.indices.contains(index) ? positions[index] : nil
            let scale: SIMD3<Float> = point == nil ? .zero : .one
            let translation = point ?? [0, -0.035, 0]
            animate(mouthBeads[index], to: Transform(scale: scale, translation: translation), duration: animated ? 0.09 : 0)
        }
    }

    private func mouthShape(for word: String, preset: ExpressionPreset) -> MouthShape {
        let lowercasedWord = word.lowercased()
        if lowercasedWord.contains("o") || lowercasedWord.contains("u") || lowercasedWord.contains("w") {
            return .oShape
        }

        if preset.mouthAmplitude > 1.15 || word.count > 6 {
            return .wideOpen
        }

        if word.count <= 2 {
            return .smallOpen
        }

        return .open
    }

    private func animate(_ entity: Entity, to transform: Transform, duration: TimeInterval) {
        if duration == 0 {
            entity.transform = transform
        } else {
            entity.move(to: transform, relativeTo: self, duration: duration, timingFunction: .easeInOut)
        }
    }
}

private struct ExpressionPreset {
    var eyeScale: SIMD3<Float>
    var browY: Float
    var leftBrowAngle: Float
    var rightBrowAngle: Float
    var pupilOffset: SIMD2<Float>
    var mouthShape: MouthShape
    var mouthAmplitude: Float

    init(emotion: Emotion) {
        switch emotion {
        case .neutral:
            eyeScale = [1.0, 1.0, 1.0]
            browY = 0.085
            leftBrowAngle = 0
            rightBrowAngle = 0
            pupilOffset = [0, 0]
            mouthShape = .closed
            mouthAmplitude = 0.9
        case .happy:
            eyeScale = [1.0, 0.78, 1.0]
            browY = 0.085
            leftBrowAngle = 0.08
            rightBrowAngle = -0.08
            pupilOffset = [0, 0.002]
            mouthShape = .smile
            mouthAmplitude = 1.0
        case .curious:
            eyeScale = [1.08, 1.08, 1.0]
            browY = 0.095
            leftBrowAngle = -0.12
            rightBrowAngle = -0.04
            pupilOffset = [0.004, 0.004]
            mouthShape = .smallOpen
            mouthAmplitude = 0.95
        case .surprised:
            eyeScale = [1.25, 1.25, 1.0]
            browY = 0.108
            leftBrowAngle = 0.02
            rightBrowAngle = -0.02
            pupilOffset = [0, 0]
            mouthShape = .oShape
            mouthAmplitude = 1.25
        case .thinking:
            eyeScale = [0.9, 0.72, 1.0]
            browY = 0.082
            leftBrowAngle = 0.14
            rightBrowAngle = 0.02
            pupilOffset = [-0.005, -0.002]
            mouthShape = .closed
            mouthAmplitude = 0.75
        case .confused:
            eyeScale = [0.95, 0.9, 1.0]
            browY = 0.092
            leftBrowAngle = -0.22
            rightBrowAngle = 0.18
            pupilOffset = [0.002, -0.002]
            mouthShape = .smallOpen
            mouthAmplitude = 0.85
        case .excited:
            eyeScale = [1.16, 1.05, 1.0]
            browY = 0.102
            leftBrowAngle = 0.12
            rightBrowAngle = -0.12
            pupilOffset = [0, 0.004]
            mouthShape = .smile
            mouthAmplitude = 1.3
        }
    }
}

private enum MouthLayout {
    static func positions(for shape: MouthShape, amplitude: Float) -> [SIMD3<Float>] {
        switch shape {
        case .closed:
            return line(y: -0.036, width: 0.062, count: 7)
        case .smallOpen:
            return oval(width: 0.045, height: 0.025 * amplitude, count: 8)
        case .open:
            return oval(width: 0.055, height: 0.042 * amplitude, count: 9)
        case .wideOpen:
            return oval(width: 0.067, height: 0.055 * amplitude, count: 9)
        case .smile:
            return smile(width: 0.074, height: 0.024 * amplitude, count: 9)
        case .oShape:
            return oval(width: 0.045, height: 0.052 * amplitude, count: 9)
        }
    }

    private static func line(y: Float, width: Float, count: Int) -> [SIMD3<Float>] {
        (0..<count).map { index in
            let t = Float(index) / Float(max(count - 1, 1))
            return [(-width / 2) + (width * t), y, 0]
        }
    }

    private static func smile(width: Float, height: Float, count: Int) -> [SIMD3<Float>] {
        (0..<count).map { index in
            let t = Float(index) / Float(max(count - 1, 1))
            let x = (-width / 2) + (width * t)
            let curve = -pow((t - 0.5) * 2, 2) + 1
            let y = -0.044 - (curve * height)
            return [x, y, 0]
        }
    }

    private static func oval(width: Float, height: Float, count: Int) -> [SIMD3<Float>] {
        (0..<count).map { index in
            let angle = (Float(index) / Float(count)) * Float.pi * 2
            return [
                cos(angle) * width / 2,
                -0.043 + sin(angle) * height / 2,
                0
            ]
        }
    }
}

private extension SIMD3 where Scalar == Float {
    static var one: SIMD3<Float> { [1, 1, 1] }
}
