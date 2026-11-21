import SwiftUI
import UIKit

/// The three-step avatar setup, plus a final review. Each step saves as it goes, so closing
/// the flow (or the app) and coming back resumes where the user left off.
struct SetupFlowView: View {
    @Environment(AvatarStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var step: SetupStep

    init(startAt step: SetupStep) { _step = State(initialValue: step) }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch step {
            case .face: FaceStepView { go(to: .body) }
            case .body: BodyPhotoStepView { go(to: .metrics) }
            case .metrics: MetricsStepView { go(to: .review) }
            case .review:
                ReviewStepView(edit: go(to:)) {
                    store.completeSetup()
                    dismiss()
                }
            }
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .preferredColorScheme(.light)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                if let previous = SetupStep(rawValue: step.rawValue - 1) {
                    Button { go(to: previous) } label: {
                        Label("Back", systemImage: "chevron.left").font(.system(size: 16, weight: .medium))
                    }
                }
                Spacer()
                Button("Save & Close") { dismiss() }
                    .font(.system(size: 16, weight: .medium))
            }
            .tint(Color.fmInk)
            .frame(minHeight: 44)

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index <= min(step.rawValue, 2) ? Color.fmCobalt : Color.black.opacity(0.12))
                        .frame(height: 4)
                }
            }
            Eyebrow(text: step == .review ? "Review" : "Step \(step.rawValue + 1) of 3")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private func go(to next: SetupStep) {
        step = next
        store.setStep(next)
    }
}

/// Shared layout for a setup step: serif title, scrolling content, actions pinned at the bottom.
struct StepScaffold<Content: View, Footer: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.fmSerif(32)).foregroundStyle(Color.fmInk)
                    Text(subtitle).font(.system(size: 16)).foregroundStyle(Color.fmSecondary)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) { footer }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.fmBackground)
        }
    }
}

struct GuidanceList: View {
    var items: [(icon: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(items, id: \.text) { item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: item.icon).foregroundStyle(Color.fmCobalt).frame(width: 22)
                    Text(item.text).font(.system(size: 15)).foregroundStyle(Color.fmInk)
                }
            }
        }
        .fmCard()
    }
}

// MARK: Step 1 — face

struct FaceStepView: View {
    var onContinue: () -> Void
    @Environment(AvatarStore.self) private var store

    @State private var showScanner = false
    @State private var showPhotoSource = false
    @State private var isProcessingPhoto = false
    @State private var photoError: String?
    @State private var cameraProblem: CameraAccess.Problem?

    private var scanSupported: Bool { FaceScanModel.isSupported }

    var body: some View {
        StepScaffold(title: "Scan your face",
                     subtitle: "Your face scan shapes your avatar's head.") {
            if let kind = store.profile.faceKind {
                review(kind)
            } else {
                intro
            }
            if let photoError { NoticeRow(tone: .caution, text: photoError) }
        } footer: {
            if isProcessingPhoto {
                ProgressView("Finding your face…").frame(minHeight: 52)
            } else if store.profile.faceKind != nil {
                Button("Continue", action: onContinue).buttonStyle(FMFilledButtonStyle())
                Button(scanSupported ? "Scan Again" : "Replace Photo") { scanSupported ? startScan() : (showPhotoSource = true) }
                    .buttonStyle(FMOutlineButtonStyle())
            } else if scanSupported {
                Button("Start Face Scan", action: startScan).buttonStyle(FMFilledButtonStyle())
                Button("Use a Photo Instead") { showPhotoSource = true }.buttonStyle(FMOutlineButtonStyle())
            } else {
                Button("Add a Front-Facing Photo") { showPhotoSource = true }.buttonStyle(FMFilledButtonStyle())
                #if DEBUG && targetEnvironment(simulator)
                Button("Use Sample Scan (Simulator only)") { store.saveFaceScan(.simulatorSample()) }
                    .buttonStyle(FMOutlineButtonStyle())
                #endif
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            FaceScanView(onCapture: { capture in
                store.saveFaceScan(capture)
                photoError = nil
                showScanner = false
            }, onCancel: { showScanner = false }, onUsePhoto: {
                showScanner = false
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    showPhotoSource = true
                }
            })
        }
        .photoSource(isPresented: $showPhotoSource, title: "Front-facing photo", camera: .front, onImage: usePhoto)
        .alert(item: $cameraProblem) { problem in
            Alert(title: Text(problem == .denied ? "Camera access is off" : "No camera available"),
                  message: Text(problem == .denied
                                ? "The face scan needs the camera. Turn on Camera for FitMix in Settings, or use a photo from your library instead."
                                : "Use a photo from your library instead."),
                  primaryButton: problem == .denied ? .default(Text("Open Settings")) { CameraAccess.openSettings() } : .cancel(),
                  secondaryButton: .default(Text("Use a Photo")) { showPhotoSource = true })
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            if scanSupported {
                GuidanceList(items: [
                    ("face.smiling", "Hold your iPhone at eye level and look straight ahead."),
                    ("arrow.triangle.2.circlepath", "Then slowly turn your head in a circle until the ring fills."),
                    ("sun.max", "Use even light, and keep your whole face uncovered."),
                ])
            } else {
                NoticeRow(tone: .info, text: "Face scanning needs a TrueDepth camera, which this device doesn't have. Use a front-facing photo instead. Your avatar's face will be a photo-based approximation.")
                    .fmCard()
                GuidanceList(items: [
                    ("face.smiling", "Face the camera directly with a neutral expression."),
                    ("sun.max", "Use even light, and keep your whole face uncovered."),
                ])
            }
        }
    }

    private func review(_ kind: FaceCaptureKind) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if let thumbnail = store.faceThumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "face.dashed").font(.system(size: 56)).foregroundStyle(Color.fmSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.fmStudio)
                }
            }
            .frame(width: 168, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Your face capture")

            switch kind {
            case .mesh:
                NoticeRow(tone: .good, text: "3D face scan saved.").fmCard()
            case .photo:
                NoticeRow(tone: .info, text: "Photo-based approximation. Your avatar's head uses this photo on a standard head shape, not a 3D scan.")
                    .fmCard()
            }
        }
    }

    private func startScan() {
        Task {
            if let problem = await CameraAccess.check() { cameraProblem = problem } else { showScanner = true }
        }
    }

    private func usePhoto(_ image: UIImage) {
        isProcessingPhoto = true
        photoError = nil
        Task {
            guard let cgImage = await image.normalizedInBackground().cgImage else {
                isProcessingPhoto = false
                return
            }
            switch await FacePhotoProcessor.cropFace(in: cgImage) {
            case .face(let crop): store.saveFacePhoto(crop: crop)
            case .noFaceFound: photoError = "No face found in that photo. Try again facing the camera in good light."
            }
            isProcessingPhoto = false
        }
    }
}

// MARK: Step 2 — full-body photo

enum PhotoCheck: Equatable {
    case checking
    case done(BodyPhotoAnalysis?)
}

/// A full-body photo with the result of the on-device check underneath.
struct BodyPhotoPreview: View {
    var image: UIImage
    var check: PhotoCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Your full-body photo")
            switch check {
            case .checking:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking the photo…").font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                }
            case .done(let analysis):
                NoticeRow(tone: analysis.notice.tone, text: analysis.notice.text)
            }
        }
    }
}

struct BodyPhotoStepView: View {
    var onContinue: () -> Void
    @Environment(AvatarStore.self) private var store

    @State private var showPhotoSource = false
    @State private var candidate: UIImage?
    @State private var check: PhotoCheck = .checking

    var body: some View {
        StepScaffold(title: "Add a full-body photo",
                     subtitle: "Used as a reference for your avatar's approximate body shape.") {
            if let candidate {
                BodyPhotoPreview(image: candidate, check: check)
            } else if let saved = store.bodyPhoto {
                BodyPhotoPreview(image: saved, check: .done(store.profile.photoAnalysis))
            } else {
                GuidanceList(items: [
                    ("figure.stand", "Stand upright in a neutral pose, arms relaxed at your sides."),
                    ("arrow.up.and.down", "Keep your full body in the frame, from head to feet."),
                    ("tshirt", "Wear fitted clothing so your outline is clear."),
                    ("sun.max", "Use even light and a plain background if you can."),
                ])
            }
        } footer: {
            if let candidate {
                Button("Use This Photo") {
                    if case .done(let analysis) = check { store.saveBodyPhoto(candidate, analysis: analysis) }
                    self.candidate = nil
                    onContinue()
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(check == .checking)
                Button("Replace Photo") { showPhotoSource = true }.buttonStyle(FMOutlineButtonStyle())
            } else if store.bodyPhoto != nil {
                Button("Continue", action: onContinue).buttonStyle(FMFilledButtonStyle())
                Button("Replace Photo") { showPhotoSource = true }.buttonStyle(FMOutlineButtonStyle())
            } else {
                Button("Add Full-Body Photo") { showPhotoSource = true }.buttonStyle(FMFilledButtonStyle())
            }
        }
        .photoSource(isPresented: $showPhotoSource, title: "Full-body photo", camera: .rear) { image in
            Task {
                let normalized = await image.normalizedInBackground()
                candidate = normalized
                check = .checking
                let analysis: BodyPhotoAnalysis? = if let cg = normalized.cgImage { await BodyPhotoAnalyzer.analyze(image: cg) } else { nil }
                if candidate === normalized { check = .done(analysis) }
            }
        }
    }
}

// MARK: Step 3 — height and weight

struct MetricsStepView: View {
    var onContinue: () -> Void
    @Environment(AvatarStore.self) private var store

    @State private var heightCm: Double?
    @State private var weightKg: Double?
    @State private var units: UnitSystem = .metric
    @State private var loaded = false

    var body: some View {
        StepScaffold(title: "Enter height and weight",
                     subtitle: "These scale your avatar. You can change them later.") {
            if loaded {
                MetricsForm(heightCm: $heightCm, weightKg: $weightKg, units: $units).fmCard()
            }
        } footer: {
            Button("Continue") {
                guard let heightCm, let weightKg else { return }
                store.setUnits(units)
                store.setMeasurements(heightCm: heightCm, weightKg: weightKg)
                onContinue()
            }
            .buttonStyle(FMFilledButtonStyle())
            .disabled(!BodyMeasurements.isValid(heightCm: heightCm, weightKg: weightKg))
        }
        .onAppear {
            guard !loaded else { return }
            heightCm = store.profile.heightCm
            weightKg = store.profile.weightKg
            units = store.profile.units
            loaded = true
        }
        .onChange(of: units) { store.setUnits(units) }
    }
}

// MARK: Review

struct ReviewStepView: View {
    var edit: (SetupStep) -> Void
    var onCreate: () -> Void
    @Environment(AvatarStore.self) private var store

    var body: some View {
        let profile = store.profile
        StepScaffold(title: "Review your captures",
                     subtitle: "Check each one, then create your avatar.") {
            VStack(spacing: 12) {
                row(step: .face, title: "Face", image: store.faceThumbnail, icon: "face.smiling",
                    detail: profile.faceKind.map { $0 == .mesh ? "3D face scan" : "Photo-based approximation" })
                row(step: .body, title: "Full-body photo", image: store.bodyThumbnail ?? store.bodyPhoto, icon: "figure.stand",
                    detail: profile.hasBodyPhoto ? profile.photoAnalysis.notice.text : nil)
                row(step: .metrics, title: "Height and weight", image: nil, icon: "ruler",
                    detail: measurementsText(profile))
            }
            NoticeRow(tone: .info, text: "Your captures and measurements are stored only on this iPhone.")
        } footer: {
            Button("Create My Avatar", action: onCreate)
                .buttonStyle(FMFilledButtonStyle())
                .disabled(profile.stepsDone < 3)
        }
    }

    private func measurementsText(_ profile: AvatarProfile) -> String? {
        guard let height = profile.heightCm, let weight = profile.weightKg else { return nil }
        return "\(BodyMeasurements.heightText(cm: height, units: profile.units)) · \(BodyMeasurements.weightText(kg: weight, units: profile.units))"
    }

    private func row(step: SetupStep, title: String, image: UIImage?, icon: String, detail: String?) -> some View {
        HStack(spacing: 14) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Color.fmSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.fmTile)
                }
            }
            .frame(width: 52, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.fmInk)
                Text(detail ?? "Not added yet")
                    .font(.system(size: 13))
                    .foregroundStyle(detail == nil ? Color.fmAmber : Color.fmSecondary)
            }
            Spacer(minLength: 8)
            Button(detail == nil ? "Add" : "Edit") { edit(step) }
                .font(.system(size: 15, weight: .semibold))
                .tint(Color.fmCobalt)
                .frame(minWidth: 44, minHeight: 44)
        }
        .fmCard(padding: 12)
    }
}
