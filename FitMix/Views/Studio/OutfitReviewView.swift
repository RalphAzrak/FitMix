import SwiftUI
import UIKit
import AVFoundation

/// Camera → **Outfit Review** → Try Full Look → Studio. Shows what the scan found on the chosen
/// person and lets the user pick which pieces to try on.
struct OutfitReviewView: View {
    var scan: OutfitScan
    /// Back to Camera to take another photo.
    var retake: () -> Void
    /// Leave without changing Studio's current look.
    var close: () -> Void
    /// Studio now has the new look.
    var openStudio: () -> Void

    @Environment(StudioStore.self) private var studio
    @Environment(AvatarStore.self) private var avatar
    @State private var selected: Set<UUID>
    @State private var askForPhoto = false
    /// "Tap to Isolate": show the garments cut out on a plain backdrop instead of the photo.
    @State private var isolated = false
    private let frame: HeroFrame

    init(scan: OutfitScan, retake: @escaping () -> Void, close: @escaping () -> Void, openStudio: @escaping () -> Void) {
        self.scan = scan
        self.retake = retake
        self.close = close
        self.openStudio = openStudio
        _selected = State(initialValue: Set(scan.garments.map(\.id)))
        frame = HeroFrame(scan: scan)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CircleIconButton(systemName: "xmark", label: "Close Outfit Review", action: close)
                Text("Outfit Review")
                    .font(.fmDisplay(22))
                    .foregroundStyle(AuthPalette.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Retake", action: retake)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AuthPalette.primary)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 12)
            .frame(height: 52)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    photo
                    if isAnalyzing {
                        NoticeRow(tone: .info, text: "Finding garments in this photo. This runs on your iPhone; the photo isn't uploaded.")
                            .accessibilityIdentifier("reviewAnalyzing")
                    } else if scan.garments.isEmpty {
                        NoticeRow(tone: .caution, text: analysis?.problem ?? "No garments were found in this photo.")
                            .accessibilityIdentifier("reviewNoGarments")
                    } else {
                        if let problem = analysis?.problem { NoticeRow(tone: .info, text: problem) }
                        HStack {
                            Text("CHOOSE PIECES TO TRY")
                                .font(.system(size: 13, weight: .bold)).tracking(0.7)
                                .foregroundStyle(Color.fmInk)
                            Spacer()
                            Text("\(selected.count) of \(scan.garments.count)")
                                .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                        }
                        ForEach(scan.garments) { garment in row(garment) }
                        Text("Pieces you don't choose stay as you're wearing them in your photo.")
                            .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                    }
                    if let note = analysis?.note { NoticeRow(tone: .info, text: note) }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
        .background(AuthPalette.surface.ignoresSafeArea())
        .preferredColorScheme(.light)
        .sheet(isPresented: $askForPhoto) {
            TryOnPhotoSheet { photo in proceed(with: photo) }
        }
    }

    /// Analysis results for this scan (not for an earlier photo).
    private var analysis: CaptureAnalysis? {
        studio.analysis.flatMap { $0.scan.id == scan.id ? $0 : nil }
    }

    private var isAnalyzing: Bool { studio.isAnalyzing && studio.pendingScan?.id == scan.id }

    private var photo: some View {
        GeometryReader { proxy in
            let fitted = AVMakeRect(aspectRatio: frame.image.size, insideRect: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                if isolated {
                    IsolatedGarments(garments: scan.garments, frame: frame, fitted: fitted, selected: $selected)
                } else {
                    Image(uiImage: frame.image)
                        .resizable().scaledToFit()
                        .frame(width: fitted.width, height: fitted.height)
                        .offset(x: fitted.minX, y: fitted.minY)
                        .accessibilityLabel("Captured outfit photo")
                        .accessibilityIdentifier("reviewPhoto")
                    ForEach(scan.garments.filter { selected.contains($0.id) }) { garment in
                        if let b = garment.bounds.flatMap(frame.convert) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(AuthPalette.primaryContainer, lineWidth: 2)
                                .frame(width: b.width * fitted.width, height: b.height * fitted.height)
                                .offset(x: fitted.minX + b.minX * fitted.width, y: fitted.minY + b.minY * fitted.height)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .containerRelativeFrame(.vertical) { length, _ in min(max(length - 300, 300), 540) }
        .background(AuthPalette.containerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottom) {
            if isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Finding garments…").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(12)
                .accessibilityElement(children: .combine)
            } else if !scan.garments.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { isolated.toggle() }
                } label: {
                    Label(isolated ? "Show Photo" : "Tap to Isolate", systemImage: isolated ? "photo" : "scissors")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(minHeight: 36)
                        .background(.black.opacity(0.6), in: Capsule())
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityHint(isolated ? "Shows the photo" : "Shows each garment cut out from the photo")
                .accessibilityIdentifier("tapToIsolate")
            }
        }
    }

    private func row(_ garment: DetectedGarment) -> some View {
        let isOn = selected.contains(garment.id)
        let piece = WorkingLook.Piece(detected: garment)
        return Button {
            if isOn { selected.remove(garment.id) } else { selected.insert(garment.id) }
        } label: {
            HStack(spacing: 12) {
                GarmentTile(source: piece.tileSource, category: garment.category)
                    .frame(width: 56, height: 62)
                VStack(alignment: .leading, spacing: 2) {
                    Text(garment.category.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AuthPalette.onSurface)
                    Text(garment.label ?? garment.matches.first?.name ?? "Not identified")
                        .font(.system(size: 13)).foregroundStyle(AuthPalette.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(isOn ? AuthPalette.primaryContainer : AuthPalette.outline)
            }
            .padding(10)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isOn ? AuthPalette.primaryContainer : AuthPalette.containerHigh, lineWidth: isOn ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("review-\(garment.category.rawValue)")
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if isAnalyzing {
                Button {} label: { Label("Finding garments…", systemImage: "hourglass") }
                    .buttonStyle(AuthPrimaryButtonStyle())
                    .disabled(true)
                    .opacity(0.5)
            } else if scan.garments.isEmpty {
                Button(action: retake) { Label("Retake Photo", systemImage: "camera") }
                    .buttonStyle(AuthPrimaryButtonStyle())
                    .accessibilityIdentifier("reviewRetake")
                Button { proceed(with: avatar.bodyPhoto) } label: { Label("Open Photo in Studio", systemImage: "arrow.right") }
                    .buttonStyle(AuthSocialButtonStyle(background: AuthPalette.container, foreground: AuthPalette.onSurface))
            } else {
                Button(action: tryFullLook) {
                    Label(selected.count == 1 ? "Try Full Look · 1 piece" : "Try Full Look · \(selected.count) pieces",
                          systemImage: "person.crop.rectangle")
                }
                .buttonStyle(AuthPrimaryButtonStyle())
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.5 : 1)
                if avatar.bodyPhoto == nil {
                    Text("You'll take a full-body photo of yourself first.")
                        .font(.system(size: 12)).foregroundStyle(AuthPalette.secondary)
                }
            }
        }
        .padding(16)
        .background(AuthPalette.surface)
        .overlay(alignment: .top) { Rectangle().fill(AuthPalette.containerHigh).frame(height: 1) }
    }

    /// Uses the saved try-on photo if there is one; otherwise asks for it, then continues with
    /// the same selection.
    private func tryFullLook() {
        if let photo = avatar.bodyPhoto { proceed(with: photo) } else { askForPhoto = true }
    }

    private func proceed(with photo: UIImage?) {
        studio.open(scan, selected: selected, tryOnSource: photo)
        openStudio()
    }
}

/// "Tap to Isolate": each garment's cutout at the place it occupies in the photo, on a plain
/// backdrop that contrasts with the clothes. Tap a garment to include or exclude it.
private struct IsolatedGarments: View {
    var garments: [DetectedGarment]
    var frame: HeroFrame
    /// Where the photo would be drawn, so cutouts sit exactly where the garments are.
    var fitted: CGRect
    @Binding var selected: Set<UUID>
    @State private var luminance: Double?

    /// Light clothes on a dark backdrop, dark clothes on a light one.
    private var darkBackdrop: Bool { (luminance ?? 0.5) > 0.55 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(darkBackdrop ? Color(red: 0.13, green: 0.13, blue: 0.15) : Color(red: 0.93, green: 0.92, blue: 0.89))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ForEach(garments) { garment in
                if let image = garment.cutout ?? garment.crop, let b = garment.bounds.flatMap(frame.convert) {
                    let isOn = selected.contains(garment.id)
                    Button {
                        withAnimation(.snappy(duration: 0.15)) {
                            if isOn { selected.remove(garment.id) } else { selected.insert(garment.id) }
                        }
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: b.width * fitted.width, height: b.height * fitted.height)
                            .shadow(color: (darkBackdrop ? Color.white : .black).opacity(isOn ? 0.35 : 0), radius: 3)
                            .opacity(isOn ? 1 : 0.3)
                            .saturation(isOn ? 1 : 0)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(isOn ? AuthPalette.primaryContainer : .gray, .white)
                                    .background(Circle().fill(.white).padding(2))
                                    .offset(x: 6, y: -6)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: fitted.minX + b.minX * fitted.width, y: fitted.minY + b.minY * fitted.height)
                    .accessibilityLabel(garment.category.title)
                    .accessibilityValue(isOn ? "Selected" : "Not selected")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("isolated-\(garment.category.rawValue)")
                }
            }
        }
        .task {
            var values: [Double] = []
            for garment in garments {
                if let cutout = garment.cutout, let l = await GarmentTone.luminance(of: cutout) { values.append(l) }
            }
            luminance = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("isolatedGarments")
    }
}
