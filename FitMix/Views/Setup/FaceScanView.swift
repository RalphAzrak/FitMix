import ARKit
import CoreImage
import SceneKit
import SwiftUI
import UIKit

/// Drives the ARKit face scan: look straight (geometry and texture are captured), then turn the head
/// until every part of the ring is filled.
@Observable
final class FaceScanModel: NSObject, ARSessionDelegate {
    enum Phase: Equatable {
        case searching, holdStraight, turning, finished
        case failed(String)
    }

    static let sectorCount = 8

    private(set) var phase: Phase = .searching
    private(set) var sectors = [Bool](repeating: false, count: FaceScanModel.sectorCount)
    private(set) var hint = ""
    /// True once the camera has delivered a picture.
    private(set) var cameraIsLive = false

    @ObservationIgnored var onFinish: ((FaceMeshCapture) -> Void)?
    @ObservationIgnored private weak var session: ARSession?
    @ObservationIgnored private var straightFrames = 0
    @ObservationIgnored private var capture: FaceMeshCapture?
    @ObservationIgnored private let ciContext = CIContext()

    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    /// Remembers the camera session. The scan starts with `restart()`, once the screen is on display.
    func attach(_ session: ARSession) {
        self.session = session
        session.delegate = self
    }

    func restart() {
        phase = .searching
        sectors = [Bool](repeating: false, count: Self.sectorCount)
        hint = ""
        straightFrames = 0
        capture = nil
        cameraIsLive = false
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = true
        session?.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session?.pause() }

    // MARK: ARSessionDelegate (delivered on the main queue)

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { process(frame) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let denied = (error as? ARError)?.code == .cameraUnauthorized
            phase = .failed(denied ? "Camera access is off for FitMix." : "The face scan stopped unexpectedly.")
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { hint = "Scan paused" }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated { if phase != .finished { restart() } }
    }

    /// Reports that the camera never produced a picture.
    func failIfCameraDidNotStart() {
        guard !cameraIsLive, phase != .finished else { return }
        phase = .failed("The camera didn't start.")
    }

    // The scan runs on every camera frame. Only write a property when its value really changes,
    // so the screen is redrawn when something happens, not 60 times a second.
    private func show(hint newHint: String) { if hint != newHint { hint = newHint } }
    private func enter(_ newPhase: Phase) { if phase != newPhase { phase = newPhase } }

    private func process(_ frame: ARFrame) {
        if !cameraIsLive { cameraIsLive = true }
        guard phase != .finished else { return }
        if case .failed = phase { return }
        guard let face = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else {
            if phase == .holdStraight { enter(.searching) }
            straightFrames = 0
            show(hint: phase == .turning ? "Keep your face inside the circle" : "")
            return
        }

        // Where the face points, relative to the camera. In portrait, the camera's x axis runs down the screen.
        let relative = frame.camera.transform.inverse * face.transform
        let forward = simd_normalize(simd_make_float3(relative.columns.2))
        let distance = simd_length(simd_make_float3(relative.columns.3))
        let right = forward.y, up = -forward.x
        let turn = (right * right + up * up).squareRoot()

        switch phase {
        case .searching, .holdStraight:
            enter(.holdStraight)
            if distance > 0.55 {
                show(hint: "Move a little closer"); straightFrames = 0
            } else if distance < 0.22 {
                show(hint: "Move a little farther away"); straightFrames = 0
            } else if turn > 0.10 {
                show(hint: "Face the screen directly"); straightFrames = 0
            } else {
                show(hint: "Hold still")
                straightFrames += 1
                if straightFrames >= 12, let captured = makeCapture(face: face, frame: frame) {
                    capture = captured
                    phase = .turning
                    hint = ""
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        case .turning:
            show(hint: "")
            guard turn > 0.15 else { return }
            var angle = atan2(up, right)
            if angle < 0 { angle += 2 * .pi }
            let step = 2 * Float.pi / Float(Self.sectorCount)
            let sector = Int((angle / step).rounded()) % Self.sectorCount
            if !sectors[sector] {
                sectors[sector] = true
                UISelectionFeedbackGenerator().selectionChanged()
            }
            if sectors.allSatisfy({ $0 }), let capture {
                phase = .finished
                stop()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onFinish?(capture)
            }
        case .finished, .failed:
            break
        }
    }

    /// Saves the face geometry, plus the part of the camera image that covers it as a texture.
    private func makeCapture(face: ARFaceAnchor, frame: ARFrame) -> FaceMeshCapture? {
        let geometry = face.geometry
        let vertices = geometry.vertices
        guard !vertices.isEmpty else { return nil }
        var mesh = FaceMeshData(vertices: vertices.flatMap { [$0.x, $0.y, $0.z] }, uvs: [],
                                indices: geometry.triangleIndices.map { UInt32($0) })

        // Project every vertex into the camera image using the camera's own intrinsics.
        // Camera space looks along -z, with +x right and +y up in the (landscape) image.
        let resolution = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        let toCamera = frame.camera.transform.inverse * face.transform
        var points: [CGPoint] = []
        points.reserveCapacity(vertices.count)
        for vertex in vertices {
            let p = toCamera * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
            let depth = -p.z
            guard depth > 0.01 else { return nil }
            points.append(CGPoint(x: CGFloat(k[2][0] + k[0][0] * p.x / depth), y: CGFloat(k[2][1] - k[1][1] * p.y / depth)))
        }
        var bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        bounds = bounds.insetBy(dx: -bounds.width * 0.06, dy: -bounds.height * 0.06)
            .intersection(CGRect(origin: .zero, size: resolution)).integral
        var texture: CGImage?
        var thumbnail: UIImage?
        if bounds.width > 32, bounds.height > 32 {
            let image = CIImage(cvPixelBuffer: frame.capturedImage)
            let cropInCI = CGRect(x: bounds.minX, y: resolution.height - bounds.maxY, width: bounds.width, height: bounds.height)
            if let cropped = ciContext.createCGImage(image, from: cropInCI) {
                texture = cropped
                mesh.uvs = points.flatMap { [Float(($0.x - bounds.minX) / bounds.width), Float(($0.y - bounds.minY) / bounds.height)] }
                // Front camera, portrait: this orientation gives an upright, mirror-style picture.
                thumbnail = UIImage(cgImage: cropped, scale: 1, orientation: .leftMirrored)
            }
        }
        return FaceMeshCapture(mesh: mesh, texture: texture, thumbnail: thumbnail)
    }
}

/// The scanning screen: live camera in a circle, a ring that fills as the head turns.
struct FaceScanView: View {
    var onCapture: (FaceMeshCapture) -> Void
    var onCancel: () -> Void
    var onUsePhoto: () -> Void

    @State private var model = FaceScanModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel", action: onCancel)
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer(minLength: 16)

                ZStack {
                    FaceScanCamera(model: model)
                        .frame(width: 262, height: 262)
                        .clipShape(Circle())
                    ScanRing(sectors: model.sectors, active: model.phase == .turning)
                        .frame(width: 320, height: 320)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Face scan, \(model.sectors.filter { $0 }.count) of \(FaceScanModel.sectorCount) directions captured")

                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(detail)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 40, alignment: .top)
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)

                Spacer(minLength: 16)

                if case .failed = model.phase {
                    Button("Try Again") { model.restart() }
                        .buttonStyle(FMFilledButtonStyle())
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
                Button("Use a photo instead", action: onUsePhoto)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 24)
            }
        }
        .onAppear { model.onFinish = onCapture }
        .onDisappear { model.stop() }
        .task {
            // Starting the camera blocks the main thread briefly, so wait until the screen has finished sliding in.
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { model.restart() }
        }
        .task(id: model.phase == .searching) {
            // If no camera picture has arrived after a few seconds, say so instead of showing a black circle.
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { model.failIfCameraDidNotStart() }
        }
    }

    private var title: String {
        switch model.phase {
        case .searching: "Position your face in the circle"
        case .holdStraight: "Look straight ahead"
        case .turning: "Slowly turn your head"
        case .finished: "Face scan complete"
        case .failed(let message): message
        }
    }

    private var detail: String {
        if !model.hint.isEmpty { return model.hint }
        switch model.phase {
        case .searching: return "Hold your iPhone at eye level, about an arm's length away."
        case .holdStraight: return "Keep a neutral expression."
        case .turning: return "Move your head in a circle until the ring is complete."
        case .finished: return ""
        case .failed: return "Close other apps that use the camera, then try again, or use a front-facing photo instead."
        }
    }
}

private struct FaceScanCamera: UIViewRepresentable {
    var model: FaceScanModel

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = false
        view.backgroundColor = .black
        model.attach(view.session)
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}

    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) { view.session.pause() }
}

/// Tick marks around the camera circle. Each of the eight directions lights up once the head has turned that way.
private struct ScanRing: View {
    var sectors: [Bool]
    var active: Bool
    private let ticksPerSector = 6

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2
            let total = sectors.count * ticksPerSector
            for tick in 0..<total {
                // Sector 0 is centred on "right"; angles run counter-clockwise on screen.
                let sector = ((tick + ticksPerSector / 2) / ticksPerSector) % sectors.count
                let filled = sectors[sector]
                let angle = Double(tick) / Double(total) * 2 * .pi
                let direction = CGPoint(x: cos(angle), y: -sin(angle))
                let length: CGFloat = filled ? 20 : 12
                var path = Path()
                path.move(to: CGPoint(x: centre.x + direction.x * (outer - length), y: centre.y + direction.y * (outer - length)))
                path.addLine(to: CGPoint(x: centre.x + direction.x * outer, y: centre.y + direction.y * outer))
                let color: Color = filled ? Color(red: 0.25, green: 0.85, blue: 0.45) : .white.opacity(active ? 0.45 : 0.22)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        .animation(.easeOut(duration: 0.2), value: sectors)
    }
}

#if DEBUG && targetEnvironment(simulator)
extension FaceMeshCapture {
    /// A made-up face-shaped surface, so the scan path can be exercised in the Simulator (which has no TrueDepth camera).
    static func simulatorSample() -> FaceMeshCapture {
        let rows = 24, columns = 20
        var vertices: [Float] = []
        var indices: [UInt32] = []
        for r in 0...rows {
            for c in 0...columns {
                let u = Float(c) / Float(columns) * 2 - 1
                let v = Float(r) / Float(rows) * 2 - 1
                let x = u * 0.072 * (1 - 0.25 * v * v)
                let y = v * 0.095
                let dome = max(0, 1 - u * u * 0.85 - v * v * 0.6).squareRoot()
                let nose = 0.022 * exp(-(u * u) / 0.03 - ((v + 0.1) * (v + 0.1)) / 0.08)
                vertices += [x, y, -0.02 + 0.07 * dome + nose]
            }
        }
        for r in 0..<rows {
            for c in 0..<columns {
                let a = UInt32(r * (columns + 1) + c), b = a + 1
                let d = UInt32((r + 1) * (columns + 1) + c), e = d + 1
                indices += [a, b, d, b, e, d]
            }
        }
        return FaceMeshCapture(mesh: FaceMeshData(vertices: vertices, uvs: [], indices: indices), texture: nil, thumbnail: nil)
    }
}
#endif
