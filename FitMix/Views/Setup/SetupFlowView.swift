import SwiftUI
import UIKit

extension SetupStep: Identifiable {
    var id: String { rawValue }
}

/// Creating an avatar: full-body photo, optional selfie, height and weight, generate, then review.
/// Each step saves as it goes, so closing the flow (or the app) and coming back resumes where the user left off.
/// The accepted avatar is only replaced when the user chooses Use This Avatar on the review step.
struct SetupFlowView: View {
    @Environment(AvatarStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var step: SetupStep

    init(startAt step: SetupStep) { _step = State(initialValue: step) }

    private static let inputSteps: [SetupStep] = [.bodyPhoto, .selfie, .measurements, .generate]

    var body: some View {
        VStack(spacing: 0) {
            header
            switch step {
            case .bodyPhoto: BodyPhotoStepView { go(to: .selfie) }
            case .selfie: SelfieStepView { go(to: .measurements) }
            case .measurements: MeasurementsStepView { go(to: .generate) }
            case .generate: GenerateStepView(onDone: { go(to: .review) }, changePhotos: { go(to: .bodyPhoto) })
            case .review:
                ReviewStepView(regenerate: { go(to: .generate) }, changePhotos: { go(to: .bodyPhoto) }) { dismiss() }
            }
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .preferredColorScheme(.light)
        .alert("Couldn't save", isPresented: Binding(get: { store.storageErrorMessage != nil },
                                                    set: { if !$0 { store.storageErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.storageErrorMessage ?? "")
        }
    }

    private var header: some View {
        let index = Self.inputSteps.firstIndex(of: step)
        return VStack(spacing: 12) {
            HStack {
                if let previous = previousStep, store.generation != .generating {
                    Button { go(to: previous) } label: {
                        Label("Back", systemImage: "chevron.left").font(.system(size: 16, weight: .medium))
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .font(.system(size: 16, weight: .medium))
            }
            .tint(Color.fmInk)
            .frame(minHeight: 44)

            HStack(spacing: 6) {
                ForEach(Self.inputSteps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= (index ?? Self.inputSteps.count) ? Color.fmCobalt : Color.black.opacity(0.12))
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
            Eyebrow(text: index.map { "Step \($0 + 1) of \(Self.inputSteps.count)" } ?? "Review")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private var previousStep: SetupStep? {
        switch step {
        case .bodyPhoto: nil
        case .selfie: .bodyPhoto
        case .measurements: .selfie
        case .generate: .measurements
        case .review: nil      // the review step has its own Regenerate and Change Photos
        }
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
                    Text(title).font(.fmSerif(32)).foregroundStyle(Color.fmInk).accessibilityAddTraits(.isHeader)
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

/// A chosen photo with the result of its on-device check underneath.
struct PhotoPreview: View {
    var image: UIImage
    var label: String
    /// `nil` while the check is still running.
    var notice: (tone: NoticeRow.Tone, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityLabel(label)
            if let notice {
                NoticeRow(tone: notice.tone, text: notice.text)
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking the photo…").font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                }
            }
        }
    }
}

// MARK: Step 1 — full-body photo

struct BodyPhotoStepView: View {
    var onContinue: () -> Void
    @Environment(AvatarStore.self) private var store

    @State private var showPhotoSource = false
    /// A photo just picked, shown before it replaces the saved one. `checked` is nil while it is being checked.
    @State private var picked: UIImage?
    @State private var checked: AvatarStore.CheckedBodyPhoto?

    var body: some View {
        StepScaffold(title: "Add a full-body photo",
                     subtitle: "Face the camera with your whole body in view, head to shoes. This is the main reference for your avatar.") {
            if let picked {
                PhotoPreview(image: checked?.image ?? picked, label: "Your full-body photo", notice: checked.map { $0.analysis.notice })
            } else if let saved = store.bodyPhoto {
                PhotoPreview(image: saved, label: "Your full-body photo", notice: store.profile.photoAnalysis.notice)
                if store.profile.avatar == nil, store.profile.candidate == nil {
                    NoticeRow(tone: .info, text: "This is the full-body photo you already saved. Keep it or replace it.")
                }
            } else if store.profile.hasBodyPhoto {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                GuidanceList(items: [
                    ("figure.stand", "Stand upright and face the camera, arms relaxed and slightly away from your sides."),
                    ("arrow.up.and.down", "Keep your whole body in the frame, from head to shoes."),
                    ("tshirt", "Wear fitted clothing so your outline is clear."),
                    ("sun.max", "Use even light and a plain background if you can."),
                ])
            }
        } footer: {
            if picked != nil {
                Button("Use This Photo") {
                    if let checked { store.saveBodyPhoto(checked.image, analysis: checked.analysis) }
                    picked = nil
                    checked = nil
                    onContinue()
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(checked == nil)
                Button("Choose Another Photo") { showPhotoSource = true }.buttonStyle(FMOutlineButtonStyle())
            } else if store.profile.hasBodyPhoto {
                Button("Continue", action: onContinue).buttonStyle(FMFilledButtonStyle())
                Button("Replace Photo") { showPhotoSource = true }.buttonStyle(FMOutlineButtonStyle())
            } else {
                Button("Add Full-Body Photo") { showPhotoSource = true }.buttonStyle(FMFilledButtonStyle())
            }
        }
        .photoSource(isPresented: $showPhotoSource, title: "Full-body photo", camera: .rear) { image in
            picked = image
            checked = nil
            Task {
                let result = await store.checkBodyPhoto(image)
                if picked === image { checked = result }
            }
        }
    }
}

// MARK: Step 2 — optional selfie

struct SelfieStepView: View {
    var onContinue: () -> Void
    @Environment(AvatarStore.self) private var store

    @State private var showPhotoSource = false
    @State private var picked: UIImage?
    @State private var checked: AvatarStore.CheckedSelfie?

    var body: some View {
        StepScaffold(title: "Add a selfie",
                     subtitle: "Optional. A close, clear photo of your face helps the avatar look like you.") {
            if let picked {
                PhotoPreview(image: checked?.image ?? picked, label: "Your selfie", notice: checked.map { Self.notice($0.hasFace) })
            } else if let saved = store.selfie {
                PhotoPreview(image: saved, label: "Your selfie", notice: Self.notice(store.profile.selfieHasFace))
            } else if store.profile.hasSelfie {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                GuidanceList(items: [
                    ("face.smiling", "Face the camera with a relaxed expression."),
                    ("sun.max", "Use even light, without strong shadows across your face."),
                    ("eyeglasses", "Take off sunglasses, hats, or anything covering your face."),
                ])
                NoticeRow(tone: .info, text: "Without a selfie, your face comes from the full-body photo, which usually shows less detail.")
            }
        } footer: {
            if picked != nil {
                Button("Use This Selfie") {
                    if let checked { store.saveSelfie(checked.image, hasFace: checked.hasFace) }
                    picked = nil
                    checked = nil
                    onContinue()
                }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(checked == nil)
                Button("Choose Another Photo") { showPhotoSource = true }.buttonStyle(FMOutlineButtonStyle())
            } else if store.profile.hasSelfie {
                Button("Continue", action: onContinue).buttonStyle(FMFilledButtonStyle())
                Button("Replace Selfie") { showPhotoSource = true }.buttonStyle(FMOutlineButtonStyle())
                Button("Remove Selfie", role: .destructive) { store.removeSelfie() }
                    .font(.system(size: 15, weight: .medium))
                    .frame(minHeight: 44)
            } else {
                Button("Add a Selfie") { showPhotoSource = true }.buttonStyle(FMFilledButtonStyle())
                Button("Continue Without a Selfie", action: onContinue).buttonStyle(FMOutlineButtonStyle())
            }
        }
        .photoSource(isPresented: $showPhotoSource, title: "Selfie", camera: .front) { image in
            picked = image
            checked = nil
            Task {
                let result = await store.checkSelfie(image)
                if picked === image { checked = result }
            }
        }
    }

    /// Only states what was actually checked.
    static func notice(_ hasFace: Bool?) -> (tone: NoticeRow.Tone, text: String) {
        switch hasFace {
        case true?: (.good, "Face found.")
        case false?: (.caution, "No face found in this photo. Try a clearer one, or continue without a selfie.")
        case nil: (.info, "The face check couldn't run on this device. Make sure your face is clear and well lit.")
        }
    }
}

// MARK: Step 3 — height and weight

struct MeasurementsStepView: View {
    var onContinue: () -> Void
    @Environment(AvatarStore.self) private var store

    @State private var heightCm: Double?
    @State private var weightKg: Double?
    @State private var units: UnitSystem = .metric
    @State private var loaded = false

    var body: some View {
        StepScaffold(title: "Height and weight",
                     subtitle: "Used alongside your photo as a cue for your overall build. Change them any time without retaking photos.") {
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

// MARK: Step 4 — consent and generation

/// Says exactly what will leave the phone, asks before sending it, then shows progress or what went wrong.
struct GenerateStepView: View {
    var onDone: () -> Void
    var changePhotos: () -> Void
    @Environment(AvatarStore.self) private var store
    /// What the avatar service said when this step opened; `nil` until it answers.
    @State private var service: AvatarServiceStatus?

    var body: some View {
        Group {
            switch store.generation {
            case .idle: consent
            case .generating: progress
            case .failed(let message): failure(message)
            }
        }
        // Finding out early that the service can't be reached beats finding out after the upload.
        .task {
            if store.generationAvailable { service = await store.serviceStatus() }
        }
        // A new portrait has arrived: move on to reviewing it.
        .onChange(of: store.profile.candidate) { old, new in
            if let new, new != old { onDone() }
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["FM_DEBUG_AUTOGENERATE"] != nil, store.generation == .idle { store.generate() }
        }
        #endif
    }

    private var consent: some View {
        let profile = store.profile
        return StepScaffold(title: "Generate your avatar",
                            subtitle: "FitMix needs your OK to send the items below to OpenAI, which draws the portrait.") {
            if !store.generationAvailable || service == .notReady {
                NoticeRow(tone: .caution, text: "Avatar generation isn't set up yet, so FitMix can't create an avatar right now.")
            } else if service == .unreachable {
                NoticeRow(tone: .caution, text: "FitMix can't reach its avatar service right now. Check your connection, then try again.")
            }
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "What will be sent")
                sentRow(image: store.bodyThumbnail ?? store.bodyPhoto, icon: "figure.stand", title: "Full-body photo", detail: "The main reference for your build")
                if profile.hasSelfie {
                    sentRow(image: store.selfie, icon: "face.smiling", title: "Selfie", detail: "For facial detail")
                } else {
                    sentRow(image: nil, icon: "face.dashed", title: "No selfie", detail: "Your face comes from the full-body photo")
                }
                sentRow(image: nil, icon: "ruler", title: "Height and weight", detail: measurements(profile))
            }
            .fmCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("FitMix sends these to its avatar service, which passes them to OpenAI to create the image. Location and other camera details are removed first.")
                Text("FitMix's service doesn't keep your photos. OpenAI handles them under its own data policy.")
                Text(profile.avatar == nil ? "The portrait is saved only on this iPhone."
                                           : "The portrait is saved only on this iPhone. Your current avatar stays until you accept a new one.")
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.fmSecondary)

        } footer: {
            Button("Agree and Generate My Avatar") { store.generate() }
                .buttonStyle(FMFilledButtonStyle())
                .disabled(!store.generationAvailable || service == .notReady || !profile.readyToGenerate)
            Button("Change Photos", action: changePhotos).buttonStyle(FMOutlineButtonStyle())
        }
    }

    private var progress: some View {
        StepScaffold(title: "Creating your avatar…", subtitle: "This usually takes a minute or two. Keep FitMix open until it's done.") {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 220)
                .accessibilityLabel("Creating your avatar")
            if store.profile.avatar != nil {
                NoticeRow(tone: .info, text: "Your current avatar stays in place while this one is made.")
            }
        } footer: {
            Button("Cancel") { store.cancelGeneration() }.buttonStyle(FMOutlineButtonStyle())
        }
    }

    private func failure(_ message: String) -> some View {
        StepScaffold(title: "Your avatar couldn't be created", subtitle: message) {
            NoticeRow(tone: .info, text: store.profile.avatar == nil ? "Your photos and measurements are still saved."
                                                                   : "Your current avatar and your photos are unchanged.")
        } footer: {
            Button("Try Again") { store.generate() }.buttonStyle(FMFilledButtonStyle())
            Button("Change Photos") {
                store.clearGenerationError()
                changePhotos()
            }
            .buttonStyle(FMOutlineButtonStyle())
        }
    }

    private func measurements(_ profile: AvatarProfile) -> String {
        guard let cm = profile.heightCm, let kg = profile.weightKg else { return "Not entered yet" }
        return "\(BodyMeasurements.heightText(cm: cm, units: profile.units)) · \(BodyMeasurements.weightText(kg: kg, units: profile.units))"
    }

    private func sentRow(image: UIImage?, icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Color.fmSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 44, height: 58)
            .background(Color.fmTile)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.fmInk)
                Text(detail).font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Step 5 — review

/// The new portrait, before it replaces anything.
struct ReviewStepView: View {
    var regenerate: () -> Void
    var changePhotos: () -> Void
    var onAccepted: () -> Void
    @Environment(AvatarStore.self) private var store

    var body: some View {
        StepScaffold(title: "Review your avatar", subtitle: "An AI-generated illustration and an approximate likeness.") {
            if let portrait = store.candidateImage {
                Image(uiImage: portrait)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("Your new avatar: a full-body animated-style portrait")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
            if let record = store.profile.candidate {
                Text(record.madeFromText(units: store.profile.units))
                    .font(.system(size: 14))
                    .foregroundStyle(Color.fmSecondary)
            }
            if store.profile.avatar != nil {
                NoticeRow(tone: .info, text: "Your current avatar stays until you choose Use This Avatar.")
            }
        } footer: {
            Button("Use This Avatar") {
                if store.acceptCandidate() { onAccepted() }
            }
            .buttonStyle(FMFilledButtonStyle())
            .disabled(store.candidateImage == nil)
            HStack(spacing: 10) {
                Button("Regenerate", action: regenerate).buttonStyle(FMOutlineButtonStyle())
                Button("Change Photos", action: changePhotos).buttonStyle(FMOutlineButtonStyle())
            }
        }
        #if DEBUG
        .onChange(of: store.candidateImage != nil, initial: true) {
            if ProcessInfo.processInfo.environment["FM_DEBUG_ACCEPT"] != nil, store.candidateImage != nil, store.acceptCandidate() { onAccepted() }
        }
        #endif
    }
}
