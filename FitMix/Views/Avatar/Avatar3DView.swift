import RealityKit
import SwiftUI
import UIKit

/// Owns the 3D avatar on screen: the loaded model, its turntable, the camera and the studio light.
///
/// One stage lives as long as its view. SwiftUI can redraw as often as it likes; the model is loaded once and
/// the same RealityKit entities are reused for every rotation.
@Observable
final class Avatar3DStage {
    enum Phase: Equatable { case loading, ready, failed }
    private(set) var phase: Phase = .loading

    @ObservationIgnored let root = Entity()
    @ObservationIgnored private let turntable = Entity()
    @ObservationIgnored private let camera = PerspectiveCamera()
    @ObservationIgnored private(set) var environment: EnvironmentResource?
    @ObservationIgnored private var loaded: URL?
    @ObservationIgnored private var yaw: Float = 0
    @ObservationIgnored private var yawAtDragStart: Float = 0
    /// Space left free above the head, as a share of the figure's height, for a label drawn over the view.
    @ObservationIgnored var roomAbove: Float = 0

    init() {
        camera.camera.fieldOfViewInDegrees = 24
        root.addChild(camera)
        root.addChild(turntable)

        // Soft studio light: an even, bright surround with a gentle key from the front.
        environment = Self.makeStudio()
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
        if let shadow = Self.makeContactShadow() { root.addChild(shadow) }

        #if DEBUG
        // FM_DEBUG_YAW (degrees) starts the avatar turned, for checking it from the side or back.
        if let degrees = ProcessInfo.processInfo.environment["FM_DEBUG_YAW"].flatMap(Float.init) { turn(to: degrees * .pi / 180) }
        #endif
    }

    /// Loads the model unless it is already on stage. If loading fails, whatever was showing stays.
    func load(_ url: URL) async {
        guard url != loaded else { return }
        if turntable.children.isEmpty { phase = .loading }
        do {
            let entity = try await Entity(contentsOf: url)
            // Stand the model on the floor, centred, whatever its own origin is.
            let bounds = entity.visualBounds(relativeTo: nil)
            entity.position = [-bounds.center.x, -bounds.min.y, -bounds.center.z]
            let height = max(bounds.extents.y, 0.5)
            turntable.children.forEach { $0.removeFromParent() }
            turntable.addChild(entity)
            loaded = url
            // Frame the whole person, head to shoes, from slightly above the midpoint.
            let distance = (height * (1.13 + roomAbove) / 2) / tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
            let lift = height * roomAbove / 2
            camera.look(at: [0, height * 0.5 + lift, 0], from: [0, height * 0.58 + lift, distance], relativeTo: nil)
            phase = .ready
        } catch {
            if turntable.children.isEmpty { phase = .failed }
        }
    }

    func beginDrag() {
        turntable.stopAllAnimations()
        yawAtDragStart = yaw
    }

    func drag(by points: CGFloat) { turn(to: yawAtDragStart + Float(points) * 0.012) }

    /// A step to the left or right, for people who turn the avatar with VoiceOver or Switch Control.
    func step(_ direction: Float) { turn(to: yaw + direction * .pi / 4) }

    func faceFront(animated: Bool) {
        yaw = 0
        var transform = turntable.transform
        transform.rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
        if animated {
            turntable.move(to: transform, relativeTo: turntable.parent, duration: 0.35, timingFunction: .easeInOut)
        } else {
            turntable.transform = transform
        }
    }

    private func turn(to angle: Float) {
        yaw = angle
        turntable.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
    }

    /// A plain studio surround: bright overhead, light walls, a slightly darker floor. It lights the model and
    /// is also what shows behind it.
    private static func makeStudio() -> EnvironmentResource? {
        let size = CGSize(width: 256, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(white: 1.0, alpha: 1).cgColor, UIColor(red: 0.95, green: 0.945, blue: 0.93, alpha: 1).cgColor,
                          UIColor(red: 0.93, green: 0.925, blue: 0.91, alpha: 1).cgColor, UIColor(red: 0.80, green: 0.795, blue: 0.78, alpha: 1).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                            locations: [0, 0.38, 0.62, 1]) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        return image.cgImage.flatMap { try? EnvironmentResource(equirectangular: $0) }
    }

    /// A soft painted shadow under the feet grounds the figure without any shadow-rendering cost.
    private static func makeContactShadow() -> Entity? {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
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

/// The user's 3D avatar on a studio backdrop. Drag sideways to turn it; double-tap to face it front again.
/// Vertical drags are left alone, so a page containing it still scrolls.
struct Avatar3DView: View {
    let modelURL: URL
    /// Shown in place of the model for the moment it takes to load, so the space is never blank.
    var placeholder: UIImage?
    /// Space to leave above the head for a label drawn over the view, as a share of the figure's height.
    var roomAbove: Float = 0
    @State private var stage = Avatar3DStage()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            if let environment = stage.environment { content.environment = .skybox(environment) }
            content.add(stage.root)
        }
        .gesture(HorizontalPan(stage: stage))
        .onTapGesture(count: 2) { stage.faceFront(animated: !reduceMotion) }
        .overlay {
            switch stage.phase {
            case .loading:
                if let placeholder {
                    ZStack {
                        Color.fmStudio
                        Image(uiImage: placeholder).resizable().scaledToFit()
                    }
                } else {
                    ProgressView().accessibilityLabel("Loading your 3D avatar")
                }
            case .failed: Text("The 3D avatar couldn't be shown.").font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
            case .ready: EmptyView()
            }
        }
        .task(id: modelURL) {
            stage.roomAbove = roomAbove
            await stage.load(modelURL)
        }
        .accessibilityElement()
        .accessibilityLabel("Your 3D avatar")
        .accessibilityHint("Drag sideways to turn it. Double-tap to face it front.")
        .accessibilityAdjustableAction { direction in
            stage.step(direction == .increment ? 1 : -1)
        }
        .accessibilityIdentifier("avatar3D")
    }
}

/// A pan that only begins for sideways drags, so the page still scrolls when the drag is vertical.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let stage: Avatar3DStage

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
