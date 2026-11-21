import AVFoundation
import SwiftUI
import UIKit

/// Camera: live rear-camera preview, Capture, then Retake / Use Photo. Use Photo hands the
/// reviewed still to Studio through `CaptureHandoff`. People tracking, tap-to-select, and garment
/// labels (issues 07–09) are not part of this screen yet; see Docs/CameraHandoff.md.
struct CameraView: View {
    /// Leaves Camera without a scan. Studio keeps whatever look it had.
    var close: () -> Void
    /// Called once with the confirmed photo.
    var capture: (ConfirmedCapture) -> Void
    /// Called once with a ready-made debug sample or fixture scan instead of a photo.
    var confirm: (OutfitScan) -> Void

    @State private var camera = CameraController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAccount = false
    @State private var showBag = false
    /// Set on the first Use Photo, so a double tap can't open Studio twice.
    @State private var confirmed = false
    #if DEBUG
    @State private var fixtureError: String?
    #endif

    private var covered: Bool { showAccount || showBag }

    var body: some View {
        VStack(spacing: 0) {
            header
            viewfinder
        }
        .background(AuthPalette.surface.ignoresSafeArea())
        .preferredColorScheme(.light)
        .task { await camera.activate() }
        .onDisappear { camera.deactivate(release: true) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: camera.deactivate(release: false)
            case .active: if !covered { Task { await camera.activate() } }
            default: break
            }
        }
        // Pause behind the bag and account screens instead of running the camera unseen.
        .onChange(of: covered) { _, covered in
            if covered { camera.deactivate(release: false) } else { Task { await camera.activate() } }
        }
        .sheet(isPresented: $showBag) { ShoppingReviewView() }
        .fullScreenCover(isPresented: $showAccount) { AccountFlowView() }
    }

    private func usePhoto() {
        guard !confirmed, let image = camera.frozen else { return }
        confirmed = true
        capture(ConfirmedCapture(image: image, capturedAt: camera.frozenAt ?? .now))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            CircleIconButton(systemName: "xmark", label: "Close Camera", action: close)
                .accessibilityIdentifier("closeCamera")
            Text("FitMix")
                .font(.system(size: 24, weight: .medium, design: .serif))
                .foregroundStyle(AuthPalette.onSurface)
            Spacer()
            Button { showBag = true } label: {
                Image(systemName: "bag")
                    .font(.system(size: 19))
                    .foregroundStyle(AuthPalette.onSurface)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Shopping bag")
            Button { showAccount = true } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(AuthPalette.primaryContainer, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Account")
        }
        .overlay {
            Text("Camera")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AuthPalette.onSurface)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    // MARK: Viewfinder

    private var showsPreview: Bool {
        switch camera.phase {
        case .starting, .live, .interrupted: true
        case .denied, .restricted, .unavailable, .failed: false
        }
    }

    private var viewfinder: some View {
        ZStack {
            Group {
                Color.black
                if showsPreview { CameraPreview(controller: camera) }
                if let frozen = camera.frozen {
                    Color.black
                    Image(uiImage: frozen)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Captured photo")
                        .accessibilityIdentifier("frozenCapture")
                }
            }
            .ignoresSafeArea(edges: .bottom)

            if camera.frozen == nil {
                switch camera.phase {
                case .live: EmptyView()
                    // HANDOFF (issues 07–08): the tracked-people overlay and tap-to-select go here,
                    // above the preview and below the controls.
                case .starting: ProgressView().tint(.white).accessibilityLabel("Starting camera")
                case .interrupted(let message): pausedNotice(message)
                case .denied, .restricted, .unavailable, .failed: statusPanel
                }
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomControls
            }
        }
    }

    private var topBar: some View {
        HStack {
            if camera.frozen != nil {
                OverlayPill(text: "Review your photo", systemImage: "photo")
            } else if camera.phase == .live {
                OverlayPill(text: "Frame an outfit", systemImage: "viewfinder")
            }
            Spacer(minLength: 0)
            #if DEBUG
            if showsPreview || camera.frozen != nil { debugSampleMenu }
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    @ViewBuilder
    private var bottomControls: some View {
        if camera.frozen != nil {
            HStack(spacing: 12) {
                Button { camera.retake() } label: { Label("Retake", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(AuthSocialButtonStyle(background: .white, foreground: AuthPalette.onSurface))
                    .accessibilityIdentifier("retake")
                Button(action: usePhoto) { Label("Use Photo", systemImage: "checkmark") }
                    .buttonStyle(AuthPrimaryButtonStyle())
                    .disabled(confirmed)
                    .accessibilityIdentifier("usePhoto")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } else if showsPreview {
            VStack(spacing: 14) {
                if let error = camera.captureError {
                    OverlayPill(text: error, systemImage: "exclamationmark.triangle.fill")
                }
                if camera.phase == .live, !camera.capabilities.zoomPresets.isEmpty { zoomControl }
                HStack {
                    torchButton.frame(width: 52)
                    Spacer()
                    shutter
                    Spacer()
                    Color.clear.frame(width: 52, height: 1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private var shutter: some View {
        Button { camera.capture() } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(.white).frame(width: 62, height: 62)
                    if camera.isCapturing { ProgressView().tint(AuthPalette.onSurface) }
                }
                Text("Capture")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            .opacity(camera.phase == .live ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(camera.phase != .live || camera.isCapturing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Capture")
        .accessibilityHint("Takes a photo of the outfit in the frame")
        .accessibilityIdentifier("capture")
    }

    @ViewBuilder
    private var torchButton: some View {
        if camera.phase == .live, camera.capabilities.hasTorch {
            Button { camera.toggleTorch() } label: {
                Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(camera.torchOn ? Color.yellow : .white)
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Torch")
            .accessibilityValue(camera.torchOn ? "On" : "Off")
        } else {
            Color.clear.frame(width: 48, height: 48)
        }
    }

    private var zoomControl: some View {
        HStack(spacing: 4) {
            ForEach(camera.capabilities.zoomPresets, id: \.self) { preset in
                let selected = preset == camera.zoom
                Button { camera.select(preset) } label: {
                    Text(preset.label)
                        .font(.system(size: 13, weight: selected ? .bold : .medium))
                        .foregroundStyle(selected ? AuthPalette.onSurface : .white)
                        .frame(width: 44, height: 36)
                        .background(selected ? Color.white : .clear, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(preset.label)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .background(.black.opacity(0.45), in: Capsule())
    }

    // MARK: States

    private func pausedNotice(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "pause.circle").font(.system(size: 34))
            Text("Camera paused").font(.system(size: 17, weight: .semibold))
            Text(message).font(.system(size: 14)).multilineTextAlignment(.center).opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(32)
        .accessibilityElement(children: .combine)
    }

    private var statusPanel: some View {
        let content = statusContent
        return ScrollView {
            VStack(spacing: 12) {
                Image(systemName: content.icon).font(.system(size: 40)).foregroundStyle(.white.opacity(0.9))
                Text(content.title)
                    .font(.system(size: 24, weight: .medium, design: .serif))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text(content.message)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                switch camera.phase {
                case .denied:
                    Button("Open Settings") { CameraAccess.openSettings() }
                        .buttonStyle(AuthPrimaryButtonStyle())
                        .padding(.top, 8)
                        .accessibilityIdentifier("openSettings")
                case .failed:
                    Button("Try Again") { camera.retry() }
                        .buttonStyle(AuthPrimaryButtonStyle())
                        .padding(.top, 8)
                default:
                    EmptyView()
                }
                #if DEBUG
                debugSampleButtons.padding(.top, 20)
                #endif
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .accessibilityIdentifier("cameraStatus")
    }

    private var statusContent: (icon: String, title: String, message: String) {
        switch camera.phase {
        case .denied:
            ("camera.fill", "Camera access is off",
             "To scan outfits, allow FitMix to use the camera: open Settings, tap Camera, and turn it on.")
        case .restricted:
            ("lock.fill", "Camera is restricted",
             "Camera use is restricted on this iPhone, for example by Screen Time. Ask whoever manages this iPhone to allow it.")
        case .unavailable:
            ("video.slash.fill", "Camera unavailable",
             "This device doesn't have a rear camera FitMix can use. Open FitMix on an iPhone to scan outfits.")
        case .failed(let message):
            ("exclamationmark.triangle.fill", "The camera couldn't start", message)
        case .starting, .live, .interrupted:
            ("camera", "", "")
        }
    }

    // MARK: Debug sample scans (FM_DEBUG_SAMPLE_SCANS=1 / FM_DEBUG_SCAN_FIXTURE)

    #if DEBUG
    /// FM_DEBUG_CAPTURE_PHOTO=/path/photo.jpg: a real photo to use as the capture in the simulator.
    private static var debugCapturePhoto: UIImage? {
        ProcessInfo.processInfo.environment["FM_DEBUG_CAPTURE_PHOTO"]
            .flatMap { UIImage(contentsOfFile: $0) }
            .map { $0.normalized(maxDimension: 3000) }
    }

    private var samplesEnabled: Bool {
        SampleScans.enabled || SampleScans.fixtureFolder != nil || ProcessInfo.processInfo.environment["FM_DEBUG_CAPTURE_PHOTO"] != nil
    }

    private func finishWithSample(_ make: () throws -> OutfitScan) {
        guard !confirmed else { return }
        do {
            let scan = try make()
            confirmed = true
            confirm(scan)
        } catch {
            fixtureError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var debugSampleButtons: some View {
        if samplesEnabled {
            VStack(spacing: 8) {
                Eyebrow(text: "Debug · stand-in Camera output", color: .white.opacity(0.6))
                if ProcessInfo.processInfo.environment["FM_DEBUG_CAPTURE_PHOTO"] != nil {
                    Button("Capture Test Photo") {
                        if let photo = Self.debugCapturePhoto { camera.debugFreeze(photo) } else { fixtureError = "FM_DEBUG_CAPTURE_PHOTO couldn't be opened." }
                    }
                    .buttonStyle(AuthSocialButtonStyle(background: .white, foreground: AuthPalette.onSurface))
                    .accessibilityIdentifier("captureTestPhoto")
                }
                if let folder = SampleScans.fixtureFolder {
                    Button("Finish with Test Photo") { finishWithSample { try SampleScans.fixtureScan(from: folder) } }
                        .buttonStyle(AuthSocialButtonStyle(background: .white, foreground: AuthPalette.onSurface))
                    if let fixtureError {
                        Text(fixtureError)
                            .font(.system(size: 13))
                            .foregroundStyle(.yellow)
                            .accessibilityIdentifier("fixtureError")
                    }
                }
                if SampleScans.enabled {
                    Button("Finish with Sample Scan A") { finishWithSample { SampleScans.scanA() } }
                        .buttonStyle(AuthSocialButtonStyle(background: .white, foreground: AuthPalette.onSurface))
                    Button("Finish with Sample Scan B") { finishWithSample { SampleScans.scanB() } }
                        .buttonStyle(AuthSocialButtonStyle(background: .white, foreground: AuthPalette.onSurface))
                }
            }
        }
    }

    @ViewBuilder
    private var debugSampleMenu: some View {
        if samplesEnabled {
            Menu {
                if let folder = SampleScans.fixtureFolder {
                    Button("Finish with Test Photo") { finishWithSample { try SampleScans.fixtureScan(from: folder) } }
                }
                if SampleScans.enabled {
                    Button("Finish with Sample Scan A") { finishWithSample { SampleScans.scanA() } }
                    Button("Finish with Sample Scan B") { finishWithSample { SampleScans.scanB() } }
                }
            } label: {
                Image(systemName: "ladybug")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Debug sample scans")
        }
    }
    #endif
}

// MARK: - Pieces

/// Short label over the viewfinder.
private struct OverlayPill: View {
    var text: String
    var systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(.black.opacity(0.5), in: Capsule())
    }
}

/// The AVFoundation preview layer, sized to the viewfinder. Aspect-fit, so the preview shows
/// exactly the frame Capture will take.
private struct CameraPreview: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = controller.session
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Camera preview"
        controller.attach(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
