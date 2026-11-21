import RealityKit
import SwiftUI
import UIKit

/// What the 3D preview should show. A new value rebuilds the avatar.
struct AvatarContent: Equatable {
    var shape: BodyShape
    var faceKind: FaceCaptureKind?
    var revision: Int
}

/// The 3D avatar on a studio backdrop. Drag sideways to rotate; change `resetToken` to face front again.
struct AvatarSceneView: UIViewRepresentable {
    var content: AvatarContent
    var files: AvatarFiles
    var resetToken: Int

    static let backdrop = UIColor(red: 0.914, green: 0.902, blue: 0.875, alpha: 1)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(Self.backdrop)
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain]
        context.coordinator.install(in: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.show(content, files: files)
        context.coordinator.reset(ifNeeded: resetToken)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let anchor = AnchorEntity(world: .zero)
        private let turntable = Entity()
        private let camera = PerspectiveCamera()
        private var content: AvatarContent?
        private var resetToken = 0
        private var yaw: Float = 0
        private var yawAtDragStart: Float = 0

        func install(in view: ARView) {
            camera.camera.fieldOfViewInDegrees = 26
            anchor.addChild(camera)
            anchor.addChild(turntable)

            let key = DirectionalLight()
            key.light.intensity = 2200
            key.look(at: [0, 0.9, 0], from: [1.6, 3.2, 3.4], relativeTo: nil)
            anchor.addChild(key)
            let fill = DirectionalLight()
            fill.light.intensity = 900
            fill.look(at: [0, 0.9, 0], from: [-2.5, 1.5, 2.0], relativeTo: nil)
            anchor.addChild(fill)

            var floorMaterial = UnlitMaterial()
            floorMaterial.color = .init(tint: UIColor(red: 0.875, green: 0.862, blue: 0.835, alpha: 1))
            let floor = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: 0.5), materials: [floorMaterial])
            floor.position = [0, -0.002, 0]
            anchor.addChild(floor)
            view.scene.addAnchor(anchor)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
        }

        func show(_ newContent: AvatarContent, files: AvatarFiles) {
            guard newContent != content else { return }
            content = newContent
            turntable.children.forEach { $0.removeFromParent() }
            let head = AvatarHead.load(kind: newContent.faceKind, files: files)
            turntable.addChild(AvatarBuilder.makeAvatar(shape: newContent.shape, head: head))

            // Frame the whole figure, head to feet.
            let height = Float(newContent.shape.heightM)
            let framed = height * 1.16
            let distance = (framed / 2) / tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
            camera.look(at: [0, height / 2, 0], from: [0, height / 2, distance], relativeTo: nil)
        }

        func reset(ifNeeded token: Int) {
            guard token != resetToken else { return }
            resetToken = token
            yaw = 0
            var transform = turntable.transform
            transform.rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
            turntable.move(to: transform, relativeTo: turntable.parent, duration: 0.35, timingFunction: .easeInOut)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                turntable.stopAllAnimations()
                yawAtDragStart = yaw
            case .changed:
                yaw = yawAtDragStart + Float(gesture.translation(in: gesture.view).x) * 0.012
                turntable.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            default:
                break
            }
        }

        /// Only take sideways drags, so vertical drags still scroll the page.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
