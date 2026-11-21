import SwiftUI
import UIKit

/// The My Avatar home screen.
struct HomeView: View {
    @Environment(AvatarStore.self) private var store

    @State private var showSetup = false
    @State private var showMetricsEditor = false
    @State private var showPhotoSource = false
    @State private var photoCandidate: PhotoCandidate?
    @State private var placeholder: PlaceholderScreen?
    @State private var confirmDelete = false
    @State private var authPreview: AuthView.Mode?

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                StatusCard(state: store.homeState, stepsDone: store.profile.stepsDone, progress: store.progressLabel)
                setupButton
                AvatarPreviewCard(retry: store.generate)
                SourceReferenceCard(changePhoto: { showPhotoSource = true })
                BodyMetricsCard(edit: { showMetricsEditor = true })
                actions
                privacy
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .defaultScrollAnchor(Self.debugScreen == "bottom" ? .bottom : .top)
        .background(Color.fmBackground.ignoresSafeArea())
        .fullScreenCover(isPresented: $showSetup) {
            SetupFlowView(startAt: store.profile.currentStep)
        }
        .fullScreenCover(item: $placeholder) { PlaceholderView(screen: $0) }
        .fullScreenCover(item: $authPreview) { AuthView(mode: $0) }
        .sheet(isPresented: $showMetricsEditor) { MetricsEditorSheet() }
        .sheet(item: $photoCandidate) { PhotoReplacementSheet(candidate: $0) }
        .photoSource(isPresented: $showPhotoSource, title: "Full-body photo", camera: .rear) { image in
            photoCandidate = PhotoCandidate(image: image.normalized())
        }
        .confirmationDialog("Delete your avatar?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Avatar and Captures", role: .destructive) { store.deleteEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your avatar, face capture, full-body photo, and measurements from this iPhone. It can't be undone.")
        }
        .alert("Couldn't save", isPresented: Binding(get: { store.storageErrorMessage != nil },
                                                    set: { if !$0 { store.storageErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.storageErrorMessage ?? "")
        }
        .onAppear {
            switch Self.debugScreen {
            case "setup": showSetup = true
            case "metrics": showMetricsEditor = true
            case "auth": authPreview = .signIn
            case "auth-create": authPreview = .createAccount
            default: break
            }
        }
    }

    /// Debug builds can open straight into a screen with FM_DEBUG_SCREEN=setup | metrics | auth | auth-create | bottom.
    private static var debugScreen: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["FM_DEBUG_SCREEN"]
        #else
        nil
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Fitting Room Suite")
            Text("My Avatar")
                .font(.fmSerif(42))
                .foregroundStyle(Color.fmInk)
                .accessibilityAddTraits(.isHeader)
            Text("Your virtual fitting room.")
                .font(.system(size: 15))
                .foregroundStyle(Color.fmSecondary)
        }
    }

    @ViewBuilder
    private var setupButton: some View {
        switch store.homeState {
        case .empty:
            Button { showSetup = true } label: { Label("Create My Avatar", systemImage: "person.crop.circle.badge.plus") }
                .buttonStyle(FMFilledButtonStyle())
        case .setupInProgress:
            Button { showSetup = true } label: { Label("Resume Setup", systemImage: "arrow.right.circle") }
                .buttonStyle(FMFilledButtonStyle())
        case .generating, .ready, .error:
            EmptyView()
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { placeholder = .scanFits } label: { Label("Open Camera to Scan Fits", systemImage: "camera") }
                .buttonStyle(FMFilledButtonStyle())
            Button { placeholder = .studio } label: { Label("Jump to Studio", systemImage: "paintpalette") }
                .buttonStyle(FMFilledButtonStyle(color: .fmCharcoal))
        }
        .padding(.top, 4)
    }

    private var privacy: some View {
        VStack(spacing: 6) {
            Text("Your face capture, photo, and measurements are stored only on this iPhone.")
                .font(.system(size: 12))
                .foregroundStyle(Color.fmSecondary)
                .multilineTextAlignment(.center)
            if store.profile.setupStarted {
                Button("Delete Avatar and Captures", role: .destructive) { confirmDelete = true }
                    .font(.system(size: 14, weight: .medium))
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Status

struct StatusCard: View {
    var state: HomeState
    var stepsDone: Int
    var progress: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(iconBackground).frame(width: 36, height: 36)
                if state == .generating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.fmInk)
                Text(detail).font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            }
            Spacer(minLength: 0)
        }
        .fmCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch state {
        case .empty, .setupInProgress: "Create your avatar"
        case .generating: "Creating avatar…"
        case .ready: "Avatar ready"
        case .error: "Avatar couldn't be created"
        }
    }

    private var detail: String {
        switch state {
        case .empty: "Scan your face, add a photo, and enter your measurements."
        case .setupInProgress: "Setup saved: \(stepsDone) of 3 steps done."
        case .generating: progress.isEmpty ? "This takes a moment." : progress
        case .ready: "Saved on this iPhone."
        case .error(let message): message
        }
    }

    private var icon: String {
        switch state {
        case .empty, .setupInProgress: "person.fill"
        case .generating: "hourglass"
        case .ready: "checkmark"
        case .error: "exclamationmark"
        }
    }

    private var iconBackground: Color {
        switch state {
        case .ready, .generating: .fmCobalt
        case .error: .fmAmber
        case .empty, .setupInProgress: .fmCharcoal
        }
    }
}

// MARK: Avatar preview

struct AvatarPreviewCard: View {
    var retry: () -> Void
    @Environment(AvatarStore.self) private var store
    @State private var resetToken = 0

    private var personalized: Bool { store.hasPersonalizedAvatar }

    private var content: AvatarContent {
        if personalized, let shape = store.profile.shape {
            return AvatarContent(shape: shape, faceKind: store.profile.faceKind, revision: store.avatarRevision)
        }
        return AvatarContent(shape: .template, faceKind: nil, revision: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Eyebrow(text: "Studio preview", color: .white.opacity(0.6))
                Spacer()
                Text(personalized ? "Your avatar" : "Template avatar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .frame(minHeight: 22)
                    .background(.white.opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ZStack {
                AvatarSceneView(content: content, files: store.files, resetToken: resetToken)
                    .accessibilityLabel(personalized ? "3D preview of your avatar" : "3D preview of a template avatar")
                Text("Drag to rotate")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.fmSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                overlay
            }
            .frame(height: 400)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 10)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(caption.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(caption.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                }
                Spacer(minLength: 8)
                Button { resetToken += 1 } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .accessibilityLabel("Reset view")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.fmCharcoal, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var caption: (title: String, detail: String) {
        guard personalized, let shape = store.profile.shape else {
            return ("Standard proportions", "Not personalized yet")
        }
        let face = store.profile.faceKind == .mesh ? "3D face scan" : "Photo-based approximation"
        let body = shape.usedPhotoOutline ? "Approximate body from photo, height, weight"
                                          : "Approximate body from height and weight"
        return (face, body)
    }

    @ViewBuilder
    private var overlay: some View {
        switch store.homeState {
        case .generating:
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text(store.progressLabel.isEmpty ? "Creating avatar…" : store.progressLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.fmInk)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.fmStudio.opacity(0.82))
        case .error(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(Color.fmAmber)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.fmInk)
                    .multilineTextAlignment(.center)
                Button("Try Again", action: retry)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Color.fmCobalt, in: Capsule())
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.fmStudio.opacity(0.9))
        case .empty, .setupInProgress, .ready:
            EmptyView()
        }
    }
}

// MARK: Source reference

struct SourceReferenceCard: View {
    var changePhoto: () -> Void
    @Environment(AvatarStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Source Reference").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.fmInk)
                Spacer()
                Button(action: changePhoto) {
                    Label(store.bodyPhoto == nil ? "Add photo" : "Change photo", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13, weight: .semibold))
                }
                .tint(Color.fmCobalt)
                .frame(minHeight: 44)
            }
            HStack(spacing: 12) {
                Group {
                    if let photo = store.bodyPhoto {
                        Image(uiImage: photo).resizable().scaledToFill()
                    } else {
                        Image(systemName: "figure.stand").font(.system(size: 24)).foregroundStyle(Color.fmSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 54, height: 72)
                .background(Color.fmCard)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    if store.bodyPhoto != nil {
                        let notice = store.profile.photoAnalysis.notice
                        Text("Full-body photo").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmInk)
                        NoticeRow(tone: notice.tone, text: notice.text).font(.system(size: 13))
                    } else {
                        Text("No full-body photo yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmInk)
                        Text("Stand upright with your full body visible, head to feet.")
                            .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.fmTile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .fmCard(padding: 14)
    }
}

struct PhotoCandidate: Identifiable {
    let id = UUID()
    var image: UIImage
}

/// Shows a replacement full-body photo before it is applied.
struct PhotoReplacementSheet: View {
    var candidate: PhotoCandidate
    @Environment(AvatarStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var check: PhotoCheck = .checking

    var body: some View {
        NavigationStack {
            ScrollView {
                BodyPhotoPreview(image: candidate.image, check: check).padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                Button("Use This Photo") {
                    if case .done(let analysis) = check { store.saveBodyPhoto(candidate.image, analysis: analysis) }
                    dismiss()
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(check == .checking)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.fmBackground)
            }
            .background(Color.fmBackground)
            .navigationTitle("New full-body photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .preferredColorScheme(.light)
        .task {
            let analysis: BodyPhotoAnalysis? = if let cg = candidate.image.cgImage { await BodyPhotoAnalyzer.analyze(image: cg) } else { nil }
            check = .done(analysis)
        }
    }
}

// MARK: Body metrics

struct BodyMetricsCard: View {
    var edit: () -> Void
    @Environment(AvatarStore.self) private var store

    var body: some View {
        let profile = store.profile
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Body Metrics").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.fmInk)
                    Text("Used to scale your avatar").font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
                }
                Spacer()
                UnitToggle(units: Binding(get: { profile.units }, set: { store.setUnits($0) }))
            }
            HStack(spacing: 10) {
                tile(label: "Height", value: heightValue(profile), footnote: heightFootnote(profile))
                tile(label: "Weight", value: weightValue(profile), footnote: weightFootnote(profile))
            }
        }
        .fmCard(padding: 14)
    }

    private func tile(label: String, value: (number: String, unit: String), footnote: String) -> some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Eyebrow(text: label)
                    Spacer()
                    Image(systemName: "pencil").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.fmSecondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value.number).font(.system(size: 28, weight: .medium)).foregroundStyle(Color.fmInk)
                    Text(value.unit).font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                Text(footnote).font(.system(size: 12)).foregroundStyle(Color.fmSecondary).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.fmTile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit height and weight")
    }

    private func heightValue(_ p: AvatarProfile) -> (String, String) {
        guard let cm = p.heightCm else { return ("—", "") }
        if p.units == .metric { return (BodyMeasurements.trimmed(cm), "cm") }
        let (feet, inches) = BodyMeasurements.feetInches(fromCm: cm)
        return ("\(feet)′ \(inches)″", "")
    }

    private func weightValue(_ p: AvatarProfile) -> (String, String) {
        guard let kg = p.weightKg else { return ("—", "") }
        return p.units == .metric ? (BodyMeasurements.trimmed(kg), "kg")
                                  : (BodyMeasurements.trimmed(BodyMeasurements.pounds(fromKg: kg)), "lb")
    }

    private func heightFootnote(_ p: AvatarProfile) -> String {
        guard let cm = p.heightCm else { return "Tap to add" }
        return BodyMeasurements.heightText(cm: cm, units: p.units == .metric ? .imperial : .metric)
    }

    private func weightFootnote(_ p: AvatarProfile) -> String {
        guard let kg = p.weightKg else { return "Tap to add" }
        guard let cm = p.heightCm else { return BodyMeasurements.weightText(kg: kg, units: p.units == .metric ? .imperial : .metric) }
        return String(format: "BMI %.1f", BodyMeasurements.bmi(heightCm: cm, weightKg: kg))
    }
}

struct MetricsEditorSheet: View {
    @Environment(AvatarStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var heightCm: Double?
    @State private var weightKg: Double?
    @State private var units: UnitSystem = .metric
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if loaded {
                    MetricsForm(heightCm: $heightCm, weightKg: $weightKg, units: $units)
                        .fmCard()
                        .padding(20)
                }
            }
            .background(Color.fmBackground)
            .navigationTitle("Height and weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let heightCm, let weightKg else { return }
                        store.setUnits(units)
                        store.setMeasurements(heightCm: heightCm, weightKg: weightKg)
                        dismiss()
                    }
                    .disabled(!BodyMeasurements.isValid(heightCm: heightCm, weightKg: weightKg))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.light)
        .onAppear {
            guard !loaded else { return }
            heightCm = store.profile.heightCm
            weightKg = store.profile.weightKg
            units = store.profile.units
            loaded = true
        }
    }
}

// MARK: Placeholders

enum PlaceholderScreen: String, Identifiable {
    case scanFits, studio
    var id: String { rawValue }

    var title: String { self == .scanFits ? "Scan Fits" : "Studio" }
    var icon: String { self == .scanFits ? "camera.viewfinder" : "paintpalette" }
    var detail: String {
        self == .scanFits ? "Scanning clothing with the camera isn't built yet. It comes after the avatar milestone."
                          : "Trying outfits on your avatar isn't built yet. It comes after the avatar milestone."
    }
}

struct PlaceholderView: View {
    var screen: PlaceholderScreen
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: screen.icon).font(.system(size: 44)).foregroundStyle(Color.fmCobalt)
            Eyebrow(text: "Placeholder")
            Text(screen.title).font(.fmSerif(34)).foregroundStyle(Color.fmInk)
            Text(screen.detail)
                .font(.system(size: 16))
                .foregroundStyle(Color.fmSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Back to My Avatar") { dismiss() }.buttonStyle(FMFilledButtonStyle(color: .fmCharcoal))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.fmBackground.ignoresSafeArea())
        .preferredColorScheme(.light)
    }
}
