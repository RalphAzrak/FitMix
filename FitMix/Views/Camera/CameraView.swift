import AVFoundation
import SwiftUI
import UIKit

/// Camera: live rear-camera preview with a tappable target on each garment found in the feed
/// (Jacket, T-shirt, Pants, Shoes). There is no shutter: tapping a target selects that one garment
/// and hands it, with the frame it was detected in, to Studio. See Docs/LiveGarmentMatch.md.
struct CameraView: View {
    /// Leaves Camera without a scan. Studio keeps whatever look it had.
    var close: () -> Void
    /// Called once with the garment the user tapped.
    var select: (LiveGarmentSelection) -> Void
    /// Called once with a ready-made debug sample or fixture scan (goes to Outfit Review).
    var confirm: (OutfitScan) -> Void

    @State private var camera = CameraController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAccount = false
    @State private var showBag = false
    /// Set on the first selection, so a double tap can't open Studio twice.
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
        .task {
            await camera.activate()
            #if DEBUG
            // FM_DEBUG_AUTO_ANALYZE=1 with FM_DEBUG_CAPTURE_PHOTO: analyze the photo as a live frame on open.
            if ProcessInfo.processInfo.environment["FM_DEBUG_AUTO_ANALYZE"] == "1", let photo = Self.debugCapturePhoto {
                camera.analyzeStill(photo, replay: Self.debugReplay)
            }
            #endif
        }
        #if DEBUG
        // FM_DEBUG_AUTO_SELECT=shoes: once that target is ready, select it the way a tap does.
        .onChange(of: camera.scan.targets) { _, targets in
            if let wanted = ProcessInfo.processInfo.environment["FM_DEBUG_AUTO_SELECT"],
               let target = targets.first(where: { $0.category.rawValue == wanted }) {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    choose(target)
                }
            }
        }
        #endif
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

    private func choose(_ target: LiveTarget) {
        guard !confirmed else { return }
        camera.select(target) { selection in
            guard !confirmed else { return }
            confirmed = true
            select(selection)
        }
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
            // Preview and targets share one frame, so the aspect-fit mapping is the same for both.
            Group {
                Color.black
                if let still = camera.stillFrame {
                    Image(uiImage: still)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Test photo analyzed as a live frame")
                } else if showsPreview {
                    CameraPreview(controller: camera)
                }
                if camera.phase == .live || camera.stillFrame != nil {
                    LiveTargetsOverlay(scan: camera.scan, disabled: camera.isSelecting || confirmed, select: choose)
                }
            }
            .ignoresSafeArea(edges: .bottom)

            if camera.stillFrame == nil {
                switch camera.phase {
                case .live: EmptyView()
                case .starting: ProgressView().tint(.white).accessibilityLabel("Starting camera")
                case .interrupted(let message): pausedNotice(message)
                case .denied, .restricted, .unavailable, .failed: statusPanel
                }
            }
            if camera.isSelecting {
                ProgressView().tint(.white).controlSize(.large).accessibilityLabel("Opening Studio")
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomControls
            }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            if camera.phase == .live || camera.stillFrame != nil {
                VStack(alignment: .leading, spacing: 6) {
                    scanPill
                    if !camera.scan.targets.isEmpty, let hint = hintText(camera.scan.hint) {
                        OverlayPill(text: hint, systemImage: "info.circle")
                    }
                }
                .animation(.easeOut(duration: 0.2), value: camera.scan.targets.isEmpty)
            }
            Spacer(minLength: 0)
            #if DEBUG
            if showsPreview || camera.stillFrame != nil { debugSampleMenu }
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    @ViewBuilder
    private var scanPill: some View {
        let scan = camera.scan
        if scan.unavailable {
            OverlayPill(text: "Live garment detection needs an iPhone", systemImage: "exclamationmark.triangle.fill")
                .accessibilityIdentifier("detectionUnavailable")
        } else if !scan.targets.isEmpty {
            OverlayPill(text: "Tap to Isolate", systemImage: "hand.tap.fill")
                .accessibilityIdentifier("tapToIsolate")
        } else {
            OverlayPill(text: hintText(scan.hint) ?? "Looking for garments…", systemImage: "viewfinder")
                .accessibilityIdentifier("scanHint")
        }
    }

    private func hintText(_ hint: LiveGarmentDetector.Hint?) -> String? {
        switch hint {
        case .noPerson: "Point at an outfit"
        case .includeFeet: "Step back to include the shoes"
        case .includeUpperBody: "Include shoulders and hips to find tops"
        case nil: nil
        }
    }

    /// Zoom and torch only: garments are picked by tapping them, so there's no shutter.
    @ViewBuilder
    private var bottomControls: some View {
        if showsPreview, camera.stillFrame == nil {
            HStack(alignment: .center) {
                torchButton.frame(width: 52)
                Spacer()
                if camera.phase == .live, !camera.capabilities.zoomPresets.isEmpty { zoomControl }
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
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

    // MARK: Debug sample scans (FM_DEBUG_SAMPLE_SCANS=1 / FM_DEBUG_SCAN_FIXTURE / FM_DEBUG_CAPTURE_PHOTO)

    #if DEBUG
    /// FM_DEBUG_CAPTURE_PHOTO=/path/photo.jpg: a real photo analyzed as if it were a live frame.
    private static var debugCapturePhoto: UIImage? {
        ProcessInfo.processInfo.environment["FM_DEBUG_CAPTURE_PHOTO"]
            .flatMap { UIImage(contentsOfFile: $0) }
            .map { $0.normalized(maxDimension: 3000) }
    }

    /// FM_DEBUG_REPLAY="shoes:0.36,0.77,0.32,0.18;pants:…": detections recorded on a Mac for the
    /// test photo, replayed because the simulator can't run Vision body pose.
    private static var debugReplay: [LiveDetection]? {
        guard let text = ProcessInfo.processInfo.environment["FM_DEBUG_REPLAY"] else { return nil }
        return text.split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let category = GarmentCategory(rawValue: String(parts[0])) else { return nil }
            let v = parts[1].split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { return nil }
            return LiveDetection(category: category, bounds: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), confidence: 1)
        }
    }

    private var samplesEnabled: Bool {
        SampleScans.enabled || SampleScans.fixtureFolder != nil || ProcessInfo.processInfo.environment["FM_DEBUG_CAPTURE_PHOTO"] != nil
    }

    /// Sample Scan A as if `category` had been tapped live: opens Studio and searches for it.
    private func selectSample(_ category: GarmentCategory) {
        guard !confirmed, let selection = SampleScans.liveSelection(category) else { return }
        confirmed = true
        select(selection)
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
                    Button("Analyze Test Photo as Live Frame") {
                        if let photo = Self.debugCapturePhoto { camera.analyzeStill(photo) } else { fixtureError = "FM_DEBUG_CAPTURE_PHOTO couldn't be opened." }
                    }
                    .buttonStyle(AuthSocialButtonStyle(background: .white, foreground: AuthPalette.onSurface))
                    .accessibilityIdentifier("captureTestPhoto")
                    if fixtureError != nil, SampleScans.fixtureFolder == nil {
                        Text(fixtureError ?? "").font(.system(size: 13)).foregroundStyle(.yellow)
                    }
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
                    Menu {
                        ForEach(GarmentCategory.liveScannable, id: \.self) { category in
                            Button("Select \(category.title)") { selectSample(category) }
                        }
                    } label: {
                        Text("Select in Sample Scan A…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AuthSocialButtonStyle(background: .white, foreground: AuthPalette.onSurface))
                    .accessibilityIdentifier("sampleLiveSelect")
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
                if let photo = Self.debugCapturePhoto {
                    Button("Analyze Test Photo as Live Frame") { camera.analyzeStill(photo) }
                }
                if SampleScans.enabled {
                    ForEach(GarmentCategory.liveScannable, id: \.self) { category in
                        Button("Sample A: Select \(category.title)") { selectSample(category) }
                    }
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

/// One tappable target per live garment, drawn where the garment is in the preview.
///
/// Frames are rotated like the preview and the preview is aspect-fit (`.resizeAspect`), so a
/// normalized frame box maps onto the screen through the same `AVMakeRect` fit, at any view size.
/// Boxes are drawn largest first: an inner T-shirt draws above the Jacket around it, so a tap on
/// the T-shirt strip selects the T-shirt and a tap on the jacket's sides or sleeves selects the
/// Jacket. Each garment also gets a labeled chip, drawn above every box and anchored where chips
/// don't collide (Jacket above its box, T-shirt in the middle, Pants beside, Shoes below), so even
/// small or overlapping targets each have one unambiguous button.
private struct LiveTargetsOverlay: View {
    var scan: LiveScanState
    var disabled: Bool
    var select: (LiveTarget) -> Void

    var body: some View {
        GeometryReader { proxy in
            let fitted = scan.frameSize.width > 0
                ? AVMakeRect(aspectRatio: scan.frameSize, insideRect: CGRect(origin: .zero, size: proxy.size))
                : .zero
            ZStack(alignment: .topLeading) {
                ForEach(scan.targets) { target in
                    let rect = screenRect(target.bounds, in: fitted)
                    TargetBox(target: target) { select(target) }
                        .frame(width: max(rect.width, 24), height: max(rect.height, 24))
                        .position(x: rect.midX, y: rect.midY)
                }
                ForEach(scan.targets) { target in
                    TargetChip(target: target) { select(target) }
                        .position(chipCenter(for: target, rect: screenRect(target.bounds, in: fitted), in: proxy.size))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .disabled(disabled)
            .animation(.easeOut(duration: 0.15), value: scan.targets)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveTargets")
    }

    private func screenRect(_ bounds: CGRect, in fitted: CGRect) -> CGRect {
        CGRect(x: fitted.minX + bounds.minX * fitted.width, y: fitted.minY + bounds.minY * fitted.height,
               width: bounds.width * fitted.width, height: bounds.height * fitted.height)
    }

    private func chipCenter(for target: LiveTarget, rect: CGRect, in size: CGSize) -> CGPoint {
        let half = CGSize(width: 50, height: 18)
        let point: CGPoint = switch target.category {
        case .jacket: CGPoint(x: rect.minX + half.width - 6, y: rect.minY - half.height - 2)
        case .pants: CGPoint(x: rect.maxX + half.width + 4, y: rect.midY)
        case .shoes: CGPoint(x: rect.midX, y: rect.maxY + half.height + 2)
        default: CGPoint(x: rect.midX, y: rect.midY)
        }
        return CGPoint(x: min(max(point.x, half.width), size.width - half.width),
                       y: min(max(point.y, half.height), size.height - half.height))
    }
}

private extension GarmentCategory {
    var targetColor: Color {
        switch self {
        case .jacket: Color(red: 0.86, green: 0.42, blue: 0.12)
        case .tshirt: Color(red: 0.11, green: 0.42, blue: 0.86)
        case .pants: Color(red: 0.13, green: 0.55, blue: 0.33)
        default: Color(red: 0.72, green: 0.16, blue: 0.48)
        }
    }
}

/// The garment's outline. Tapping inside it selects the garment.
private struct TargetBox: View {
    var target: LiveTarget
    var action: () -> Void

    var body: some View {
        let color = target.category.targetColor
        Button(action: action) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 2.5, dash: target.category == .tshirt ? [6, 4] : []))
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        // The chip is the accessible control; the outline would only repeat it.
        .accessibilityHidden(true)
    }
}

/// The garment's label, also a button: the one control VoiceOver and small targets rely on.
private struct TargetChip: View {
    var target: LiveTarget
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(target.category.title, systemImage: "hand.tap.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .background(target.category.targetColor, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .fixedSize()
                .frame(minWidth: 44, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.category.title)
        .accessibilityHint("Selects the \(target.category.title.lowercased()) and finds it at retailers")
        .accessibilityIdentifier("liveTarget-\(target.category.rawValue)")
    }
}

/// The AVFoundation preview layer, sized to the viewfinder. Aspect-fit, so the preview shows
/// exactly the frame being analyzed.
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
