import RealityKit
import SwiftUI
import UIKit

/// Poses for checking how the character deforms. `standing` is the pose the model was exported in.
enum AvatarModelPose: String {
    case standing
    /// Left elbow bent, right arm raised to the side, left hip and knee bent.
    case jointTest
}

/// Owns the 3D avatar: the loaded model, its turntable, camera and studio lighting.
///
/// One stage lives for the life of the screen. SwiftUI can redraw as often as it likes; the model is loaded once,
/// off the main thread, and the same RealityKit entities are reused for every update, rotation and scroll.
@Observable
final class AvatarStage {
    private(set) var isLoading = true
    private(set) var loadFailed = false

    @ObservationIgnored let root = Entity()
    @ObservationIgnored private let turntable = Entity()
    @ObservationIgnored private let camera = PerspectiveCamera()
    @ObservationIgnored private(set) var environment: EnvironmentResource?
    @ObservationIgnored private var loadedURL: URL?
    @ObservationIgnored private var model: Entity?
    @ObservationIgnored private var skinned: [(entity: ModelEntity, rest: [Transform])] = []
    @ObservationIgnored private var yaw: Float = 0
    @ObservationIgnored private var yawAtDragStart: Float = 0
    @ObservationIgnored private var pose: AvatarModelPose = .standing
    @ObservationIgnored private var spinLink: CADisplayLink?

    init() {
        camera.camera.fieldOfViewInDegrees = 24
        root.addChild(camera)
        root.addChild(turntable)

        // Soft studio lighting: an even, bright surround with a gentle key from the front.
        environment = Self.makeStudioEnvironment()
        if let environment {
            let surround = Entity()
            surround.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.55))
            root.addChild(surround)
            turntable.components.set(ImageBasedLightReceiverComponent(imageBasedLight: surround))
        }
        let key = DirectionalLight()
        key.light.intensity = 2400
        key.look(at: [0, 1, 0], from: [1.8, 3.0, 3.2], relativeTo: nil)
        root.addChild(key)

        // A soft painted shadow under the feet grounds the figure without any shadow-rendering cost.
        if let shadow = Self.makeContactShadow() { root.addChild(shadow) }

        #if DEBUG
        // FM_DEBUG_YAW (radians) starts the avatar turned, for checking it from the side or back.
        if let value = ProcessInfo.processInfo.environment["FM_DEBUG_YAW"], let radians = Float(value) {
            yaw = radians
            turntable.orientation = simd_quatf(angle: radians, axis: [0, 1, 0])
        }
        #endif
    }

    // MARK: Loading

    /// Loads the model if it is not already on stage. If loading fails, whatever was showing stays.
    func load(_ url: URL) async {
        guard url != loadedURL else { return }
        isLoading = true
        loadFailed = false
        do {
            #if FM_BENCH
            let start = ContinuousClock.now
            #endif
            let entity = try await Entity(contentsOf: url)
            Self.prepareMaterials(in: entity)

            // Stand the model on the floor, centred, whatever its own origin is.
            let bounds = entity.visualBounds(relativeTo: nil)
            entity.position = [-bounds.center.x, -bounds.min.y, -bounds.center.z]
            let height = max(bounds.extents.y, 0.5)

            model?.removeFromParent()
            turntable.addChild(entity)
            model = entity
            loadedURL = url
            skinned = Self.skinnedModels(in: entity).map { ($0, $0.jointTransforms) }
            apply(pose)

            // Frame the whole person, head to shoes, from slightly above the midpoint.
            let distance = (height * 1.13 / 2) / tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
            camera.look(at: [0, height * 0.5, 0], from: [0, height * 0.58, distance], relativeTo: nil)
            #if FM_BENCH
            print("FM_TIMING load \(ContinuousClock.now - start) skinned meshes \(skinned.count)")
            #endif
        } catch {
            loadFailed = model == nil
        }
        isLoading = false
    }

    private static func skinnedModels(in entity: Entity) -> [ModelEntity] {
        var found: [ModelEntity] = []
        func visit(_ e: Entity) {
            if let model = e as? ModelEntity, !model.jointNames.isEmpty { found.append(model) }
            e.children.forEach(visit)
        }
        visit(entity)
        return found
    }

    /// Hair and eyebrows are cut out by their texture's alpha. Drawing them as alpha-tested cut-outs rather than
    /// blended transparency keeps them crisp and correctly sorted from every angle.
    private static func prepareMaterials(in entity: Entity) {
        func visit(_ e: Entity, threshold: Float?) {
            let name = e.name.lowercased()
            let threshold = name.contains("eyebrow") ? 0.5 : (name.contains("hair") ? 0.35 : threshold)
            if var component = e.components[ModelComponent.self] {
                component.materials = component.materials.map { material in
                    guard var pbr = material as? PhysicallyBasedMaterial else { return material }
                    if case .transparent = pbr.blending {
                        pbr.faceCulling = .none
                        pbr.opacityThreshold = threshold ?? 0.4
                    }
                    return pbr
                }
                e.components.set(component)
            }
            e.children.forEach { visit($0, threshold: threshold) }
        }
        visit(entity, threshold: nil)
    }

    // MARK: Rotation

    func beginDrag() {
        turntable.stopAllAnimations()
        yawAtDragStart = yaw
    }

    func drag(by points: CGFloat) {
        yaw = yawAtDragStart + Float(points) * 0.012
        turntable.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
    }

    func resetView() {
        yaw = 0
        var transform = turntable.transform
        transform.rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
        turntable.move(to: transform, relativeTo: turntable.parent, duration: 0.35, timingFunction: .easeInOut)
    }

    /// Turns the avatar continuously, the way a drag would. Used by the profiling benchmark.
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
        turntable.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
    }

    // MARK: Poses

    func setPose(_ newPose: AvatarModelPose) {
        guard newPose != pose else { return }
        pose = newPose
        apply(newPose)
    }

    /// Poses every skinned mesh the same way, so skin and clothes bend together.
    /// Rotations are about the skeleton's own axes through each joint. The skeleton keeps Blender's convention:
    /// x points to the character's left, y behind it, and z up.
    private func apply(_ pose: AvatarModelPose) {
        let bends: [(joint: String, axis: SIMD3<Float>, degrees: Float)] = pose == .standing ? [] : [
            ("lowerarm_l", [1, 0, 0], -85),
            ("upperarm_r", [0, 1, 0], 70),
            ("thigh_l", [1, 0, 0], -40),
            ("calf_l", [1, 0, 0], 70),
        ]
        for (entity, rest) in skinned {
            var transforms = rest
            let names = entity.jointNames
            // Each joint's orientation in model space, from the rest pose.
            var global = [simd_quatf](repeating: simd_quatf(angle: 0, axis: [0, 1, 0]), count: names.count)
            var parent = [Int](repeating: -1, count: names.count)
            for (i, name) in names.enumerated() {
                if let slash = name.lastIndex(of: "/"), let p = names.firstIndex(of: String(name[..<slash])) { parent[i] = p }
                global[i] = parent[i] >= 0 ? global[parent[i]] * rest[i].rotation : rest[i].rotation
            }
            for bend in bends {
                guard let i = names.firstIndex(where: { $0.hasSuffix("/" + bend.joint) || $0 == bend.joint }) else { continue }
                let turn = simd_quatf(angle: bend.degrees * .pi / 180, axis: simd_normalize(bend.axis))
                let parentRotation = parent[i] >= 0 ? global[parent[i]] : simd_quatf(angle: 0, axis: [0, 1, 0])
                transforms[i].rotation = parentRotation.inverse * turn * parentRotation * rest[i].rotation
            }
            entity.jointTransforms = transforms
        }
    }

    // MARK: Studio

    /// A plain studio surround: bright overhead, light walls, a slightly darker floor. It lights the model and is
    /// also what shows behind it.
    private static func makeStudioEnvironment() -> EnvironmentResource? {
        let width = 256, height = 128
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                               format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; return f }())
        let image = renderer.image { context in
            let colors = [UIColor(white: 1.0, alpha: 1).cgColor, UIColor(red: 0.95, green: 0.945, blue: 0.93, alpha: 1).cgColor,
                          UIColor(red: 0.93, green: 0.925, blue: 0.91, alpha: 1).cgColor, UIColor(red: 0.80, green: 0.795, blue: 0.78, alpha: 1).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                            locations: [0, 0.38, 0.62, 1]) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? EnvironmentResource(equirectangular: cgImage)
    }

    private static func makeContactShadow() -> Entity? {
        let size = CGSize(width: 128, height: 128)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(white: 0, alpha: 0.34).cgColor, UIColor(white: 0, alpha: 0.10).cgColor, UIColor(white: 0, alpha: 0).cgColor]
            guard let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 0.5, 1]) else { return }
            let centre = CGPoint(x: 64, y: 64)
            context.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 64, options: [])
        }
        guard let cgImage = image.cgImage,
              let texture = try? TextureResource(image: cgImage, options: .init(semantic: .color)) else { return nil }
        var material = UnlitMaterial(texture: texture)
        material.blending = .transparent(opacity: 1.0)
        let shadow = ModelEntity(mesh: .generatePlane(width: 0.95, depth: 0.6), materials: [material])
        shadow.position = [0, 0.002, 0.03]
        return shadow
    }
}

/// The avatar on its studio backdrop. Drag sideways to rotate; vertical drags scroll the page as usual.
struct AvatarModelView: View {
    let stage: AvatarStage
    let modelURL: URL?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            if let environment = stage.environment { content.environment = .skybox(environment) }
            content.add(stage.root)
        }
        .gesture(HorizontalPan(stage: stage))
        .task(id: modelURL) {
            if let modelURL { await stage.load(modelURL) }
        }
    }
}

/// A pan that only begins for sideways drags, so the page still scrolls when the drag is vertical.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let stage: AvatarStage

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began: stage.beginDrag()
        case .changed: stage.drag(by: recognizer.translation(in: recognizer.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
