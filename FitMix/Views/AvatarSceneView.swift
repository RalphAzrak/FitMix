import SceneKit
import SwiftUI
import UIKit

/// What the 3D preview should show. A new value rebuilds the avatar.
nonisolated struct AvatarContent: Equatable, Sendable {
    var shape: BodyShape
    var faceKind: FaceCaptureKind?
    var revision: Int
}

/// The 3D avatar on a studio backdrop. Drag sideways to rotate; change `resetToken` to face front again.
///
/// The avatar is built and prepared for drawing off the main thread, so the page stays responsive while it
/// loads, and the view only redraws when the avatar changes or turns, so it costs nothing while the page scrolls.
struct AvatarSceneView: UIViewRepresentable {
    var content: AvatarContent
    var files: AvatarFiles
    var resetToken: Int
    /// Turns the avatar continuously, the way a drag would. Used by the profiling benchmark.
    var spin = false
    var pose: AvatarPose = .standing
    @Binding var isLoading: Bool

    static let backdrop = UIColor(red: 0.945, green: 0.937, blue: 0.918, alpha: 1)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = Self.backdrop
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.isPlaying = false
        view.allowsCameraControl = false
        context.coordinator.install(in: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let isLoading = $isLoading
        context.coordinator.show(content, files: files, in: view) { isLoading.wrappedValue = $0 }
        context.coordinator.reset(ifNeeded: resetToken)
        context.coordinator.setSpinning(spin)
        context.coordinator.setPose(pose)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) { coordinator.tearDown() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The last avatar built, kept so reopening the screen shows it at once instead of rebuilding it.
        private static var cache: (content: AvatarContent, node: SCNNode)?

        private let scene = SCNScene()
        private let turntable = SCNNode()
        private let cameraNode = SCNNode()
        private var content: AvatarContent?
        private var buildTask: Task<Void, Never>?
        private var resetToken = 0
        private var yaw: Float = 0
        private var yawAtDragStart: Float = 0
        private var spinLink: CADisplayLink?
        private var pose: AvatarPose = .standing

        override init() {
            super.init()
            #if DEBUG
            // FM_DEBUG_YAW (radians) starts the avatar turned, for checking it from the side or back.
            if let value = ProcessInfo.processInfo.environment["FM_DEBUG_YAW"], let radians = Float(value) {
                yaw = radians
                turntable.simdOrientation = simd_quatf(angle: radians, axis: [0, 1, 0])
            }
            #endif
        }

        func install(in view: SCNView) {
            scene.background.contents = AvatarSceneView.backdrop

            let camera = SCNCamera()
            camera.fieldOfView = 22
            camera.zNear = 0.1
            camera.zFar = 40
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)
            scene.rootNode.addChildNode(turntable)

            // Soft studio light: bright even fill, a key light from the front, and a faint shadow at the feet.
            addLight(.ambient, intensity: 560)
            addLight(.directional, intensity: 560, from: [0.9, 3.6, 3.2])
            addLight(.directional, intensity: 230, from: [-2.6, 1.6, 2.2])

            // A soft painted shadow under the feet: it grounds the figure without any shadow rendering cost.
            let shadow = SCNPlane(width: 0.95, height: 0.62)
            let shadowMaterial = SCNMaterial()
            shadowMaterial.lightingModel = .constant
            shadowMaterial.diffuse.contents = Self.softShadowImage()
            shadowMaterial.writesToDepthBuffer = false
            shadow.materials = [shadowMaterial]
            let shadowNode = SCNNode(geometry: shadow)
            shadowNode.simdOrientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            shadowNode.simdPosition = [0, 0.001, 0.02]
            shadowNode.renderingOrder = -1
            scene.rootNode.addChildNode(shadowNode)

            view.scene = scene
            view.pointOfView = cameraNode

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
        }

        private static func softShadowImage() -> UIImage {
            let size = CGSize(width: 128, height: 128)
            return UIGraphicsImageRenderer(size: size).image { context in
                let colors = [UIColor(white: 0, alpha: 0.30).cgColor, UIColor(white: 0, alpha: 0.10).cgColor, UIColor(white: 0, alpha: 0).cgColor]
                guard let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 0.5, 1]) else { return }
                let centre = CGPoint(x: 64, y: 64)
                context.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 64, options: [])
            }
        }

        @discardableResult
        private func addLight(_ type: SCNLight.LightType, intensity: CGFloat, from position: SIMD3<Float> = .zero) -> SCNLight {
            let light = SCNLight()
            light.type = type
            light.intensity = intensity
            let node = SCNNode()
            node.light = light
            if type == .directional {
                node.simdPosition = position
                node.simdLook(at: [0, 0.9, 0])
            }
            scene.rootNode.addChildNode(node)
            return light
        }

        func show(_ newContent: AvatarContent, files: AvatarFiles, in view: SCNView, setLoading: @escaping (Bool) -> Void) {
            guard newContent != content else { return }
            content = newContent
            buildTask?.cancel()
            if let cached = Self.cache, cached.content == newContent {
                cached.node.removeFromParentNode()
                swapIn(cached.node, height: Float(newContent.shape.heightM))
                Task { setLoading(false) }
                return
            }
            buildTask = Task { [weak self, weak view] in
                setLoading(true)
                // Geometry is built on a background thread, then SceneKit compiles its shaders and uploads
                // it to the GPU there too. Only the final swap happens on the main thread.
                let built = await AvatarBuilder.build(newContent, files: files)
                guard !Task.isCancelled, let view else { return }
                #if FM_BENCH
                let prepareStart = ContinuousClock.now
                #endif
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    view.prepare([built.node]) { _ in done.resume() }
                }
                #if FM_BENCH
                print("FM_TIMING prepare \(ContinuousClock.now - prepareStart)")
                #endif
                guard !Task.isCancelled, let self else { return }
                Self.cache = (newContent, built.node)
                self.swapIn(built.node, height: Float(newContent.shape.heightM))
                setLoading(false)
            }
        }

        private func swapIn(_ avatar: SCNNode, height: Float) {
            // Frame the whole figure, head to feet.
            let fieldOfView = Float(cameraNode.camera?.fieldOfView ?? 22)
            let distance = (height * 1.14 / 2) / tan(fieldOfView * .pi / 360)
            // Slightly above the midpoint and looking down a touch, like a studio full-length shot.
            cameraNode.simdPosition = [0, height * 0.60, distance]
            cameraNode.simdLook(at: [0, height * 0.505, 0])

            AvatarBuilder.apply(pose, to: avatar)
            let old = turntable.childNodes
            avatar.opacity = old.isEmpty ? 0 : 1
            turntable.addChildNode(avatar)
            old.forEach { $0.removeFromParentNode() }
            if avatar.opacity == 0 {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.25
                avatar.opacity = 1
                SCNTransaction.commit()
            }
        }

        func setPose(_ newPose: AvatarPose) {
            guard newPose != pose else { return }
            pose = newPose
            guard let avatar = turntable.childNodes.first else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.45
            AvatarBuilder.apply(newPose, to: avatar)
            SCNTransaction.commit()
        }

        func tearDown() {
            buildTask?.cancel()
            spinLink?.invalidate()
            spinLink = nil
        }

        func reset(ifNeeded token: Int) {
            guard token != resetToken else { return }
            resetToken = token
            yaw = 0
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.35
            turntable.simdOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])
            SCNTransaction.commit()
        }

        func setSpinning(_ spinning: Bool) {
            guard spinning != (spinLink != nil) else { return }
            spinLink?.invalidate()
            spinLink = nil
            if spinning {
                let link = CADisplayLink(target: self, selector: #selector(spinStep))
                link.add(to: .main, forMode: .common)
                spinLink = link
            }
        }

        @objc private func spinStep() {
            yaw += 0.03
            turntable.simdOrientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                turntable.removeAllAnimations()
                yawAtDragStart = yaw
            case .changed:
                yaw = yawAtDragStart + Float(gesture.translation(in: gesture.view).x) * 0.012
                turntable.simdOrientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
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
