import SwiftUI
import UIKit

/// Profile: the user's avatar, the photo it was made from, and their measurements.
///
/// It shows the same saved data as Home (`AvatarStore`), so a change made here is on Home the moment it is
/// accepted. Capturing, checking, generating and saving all happen in the store and its services; this view
/// only shows state and passes the user's choices on.
struct AvatarProfileView: View {
    /// Opens the avatar flow at a step. The current avatar stays until a replacement is accepted there.
    var changeAvatar: (SetupStep) -> Void
    var editMetrics: () -> Void
    var openAccount: () -> Void

    @Environment(AvatarStore.self) private var store
    @Environment(AuthSession.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var askHowToChange = false
    @State private var showPhotoSource = false
    @State private var showSelfieSource = false
    /// True while a newly picked photo is being prepared and checked.
    @State private var checking = false
    @State private var newPhoto: AvatarStore.CheckedBodyPhoto?
    @State private var newSelfie: AvatarStore.CheckedSelfie?
    @State private var showFullPhoto = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Profile")
                    .font(.fmSerif(38))
                    .foregroundStyle(Color.fmInk)
                    .accessibilityAddTraits(.isHeader)
                avatarSection
                photoSection
                BodyMetricsCard(edit: editMetrics)
                if store.homeState == .ready, store.profile.measurementsChangedSinceAvatar { measurementsChanged }
                accountSection
                privacy
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        #if DEBUG
        // FM_DEBUG_SCROLL=bottom opens the page scrolled to its end, for checking the lower sections.
        .defaultScrollAnchor(ProcessInfo.processInfo.environment["FM_DEBUG_SCROLL"] == "bottom" ? .bottom : .top)
        #endif
        .background(Color.fmBackground.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        // The page has its own large title; the bar keeps only the back button.
        .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) } }
        .toolbarBackground(Color.fmBackground, for: .navigationBar)
        #if DEBUG
        // FM_DEBUG_PROFILE=change-reuse | change-update | review | ask | photo | replace takes the matching action
        // straight away ("replace" treats the saved photo as one just picked).
        .task {
            switch ProcessInfo.processInfo.environment["FM_DEBUG_PROFILE"] {
            case "change-reuse": changeAvatar(.generate)
            case "change-update": changeAvatar(.bodyPhoto)
            case "review": changeAvatar(.review)
            case "ask": askHowToChange = true
            case "photo", "replace":
                try? await Task.sleep(for: .seconds(1.5))
                guard let photo = store.bodyPhoto else { break }
                if ProcessInfo.processInfo.environment["FM_DEBUG_PROFILE"] == "photo" { showFullPhoto = true } else { newPhoto = await store.checkBodyPhoto(photo) }
            default: break
            }
        }
        #endif
        .confirmationDialog("Change your avatar", isPresented: $askHowToChange, titleVisibility: .visible) {
            Button("Use My Current Photo and Measurements") { changeAvatar(.generate) }
            Button("Update Photo or Measurements First") { changeAvatar(.bodyPhoto) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll see the new avatar before anything changes. Your current one stays until you choose Use This Avatar.")
        }
        .sheet(item: $newPhoto) { checked in
            PhotoConfirmSheet(title: "New full-body photo", image: checked.image, label: "Your new full-body photo",
                              notice: checked.analysis.notice, useLabel: "Use This Photo") {
                store.saveBodyPhoto(checked.image, analysis: checked.analysis)
            }
        }
        .sheet(item: $newSelfie) { checked in
            PhotoConfirmSheet(title: "New selfie", image: checked.image, label: "Your new selfie",
                              notice: SelfieStepView.notice(checked.hasFace), useLabel: "Use This Selfie") {
                store.saveSelfie(checked.image, hasFace: checked.hasFace)
            }
        }
        .fullScreenCover(isPresented: $showFullPhoto) {
            if let photo = store.bodyPhoto {
                ZoomableImageView(image: photo, focus: nil, focusLabel: nil, label: "Your full-body photo")
            }
        }
        .confirmationDialog("Delete your avatar?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Avatar and Photos", role: .destructive) { store.deleteEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your avatar, full-body photo, selfie, and measurements from this iPhone. It can't be undone.")
        }
    }

    // MARK: My Avatar

    private var avatarSection: some View {
        let record = store.profile.avatar
        return AvatarProfileSection(title: "My Avatar") {
            Group {
                if let portrait = store.avatarImage {
                    // The whole figure in the portrait's own shape: no backdrop bars, nothing cropped.
                    Image(uiImage: portrait)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(maxHeight: 420)
                        .id(record?.createdAt)
                        .transition(.opacity)
                        .accessibilityLabel("Your avatar: a full-body animated-style portrait")
                } else {
                    ZStack {
                        Color.fmStudio
                        if record != nil {
                            ProgressView().accessibilityLabel("Loading your avatar")
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "figure.stand").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(Color.fmSecondary.opacity(0.6))
                                Text("No avatar yet").font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: record?.createdAt)

            if let record {
                Text("AI-generated illustration and an approximate likeness. \(record.madeFromText(units: store.profile.units))")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fmSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            avatarActions
        }
    }

    /// What can be done next depends on whether a new avatar is being made, waiting for review, or neither.
    @ViewBuilder
    private var avatarActions: some View {
        switch store.homeState {
        case .generating:
            HStack(spacing: 10) {
                ProgressView()
                Text("Creating your new avatar…").font(.system(size: 14)).foregroundStyle(Color.fmInk)
            }
            .accessibilityElement(children: .combine)
            Button("View Progress") { changeAvatar(.generate) }.buttonStyle(FMOutlineButtonStyle())
        case .reviewPending:
            NoticeRow(tone: .info, text: store.profile.avatar == nil ? "A new avatar is ready to review."
                                                                    : "A new avatar is ready. Your current one stays until you choose Use This Avatar.")
            Button("Review New Avatar") { changeAvatar(.review) }.buttonStyle(FMFilledButtonStyle())
        case .error(let message):
            NoticeRow(tone: .caution, text: message)
            Button("Try Again") { changeAvatar(.generate) }.buttonStyle(FMFilledButtonStyle())
        case .ready:
            Button("Change Avatar") {
                // With a photo and measurements already saved, offer to reuse them as they are.
                if store.profile.readyToGenerate { askHowToChange = true } else { changeAvatar(.bodyPhoto) }
            }
            .buttonStyle(FMFilledButtonStyle())
        case .empty, .setupInProgress:
            Button(store.profile.setupStarted ? "Continue Setup" : "Create My Avatar") { changeAvatar(store.resumeStep) }
                .buttonStyle(FMFilledButtonStyle())
        }
    }

    // MARK: Original photo

    private var photoSection: some View {
        let profile = store.profile
        return AvatarProfileSection(title: "Original Full-Body Photo") {
            if let photo = store.bodyPhoto {
                // The photo as it was taken: its own shape, nothing cropped. Tap to see it full screen.
                Button { showFullPhoto = true } label: {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("Your full-body photo")
                .accessibilityHint("Opens it full screen")
                NoticeRow(tone: profile.photoAnalysis.notice.tone, text: profile.photoAnalysis.notice.text)
                Text("This is the main reference the next time you generate an avatar.")
                    .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            } else if profile.hasBodyPhoto {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Text("No full-body photo yet. Add one that shows your whole body, head to shoes.")
                    .font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
            }
            if checking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking the photo…").font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                }
            }
            Button(profile.hasBodyPhoto ? "Replace Photo" : "Add Full-Body Photo") { showPhotoSource = true }
                .buttonStyle(FMOutlineButtonStyle())
                .disabled(checking)
                .photoSource(isPresented: $showPhotoSource, title: "Full-body photo", camera: .rear) { picked in
                    checking = true
                    Task {
                        newPhoto = await store.checkBodyPhoto(picked)
                        checking = false
                    }
                }
            selfieRow
        }
    }

    private var selfieRow: some View {
        let profile = store.profile
        return HStack(spacing: 12) {
            Group {
                if let selfie = store.selfie {
                    Image(uiImage: selfie).resizable().scaledToFill()
                } else {
                    Image(systemName: profile.hasSelfie ? "face.smiling" : "face.dashed").font(.system(size: 20)).foregroundStyle(Color.fmSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 44, height: 58)
            .background(Color.fmCard)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.hasSelfie ? "Selfie" : "No selfie").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmInk)
                Text(profile.hasSelfie ? "Used for facial detail" : "Optional. Adds facial detail.")
                    .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
            }
            Spacer(minLength: 8)
            if profile.hasSelfie {
                Menu {
                    Button("Replace Selfie") { showSelfieSource = true }
                    Button("Remove Selfie", role: .destructive) { store.removeSelfie() }
                } label: {
                    Text("Change").font(.system(size: 14, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
                }
                .tint(Color.fmCobalt)
            } else {
                Button("Add") { showSelfieSource = true }
                    .font(.system(size: 14, weight: .semibold))
                    .tint(Color.fmCobalt)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(10)
        .background(Color.fmTile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .photoSource(isPresented: $showSelfieSource, title: "Selfie", camera: .front) { picked in
            checking = true
            Task {
                newSelfie = await store.checkSelfie(picked)
                checking = false
            }
        }
    }

    // MARK: Measurements, account, privacy

    /// Height or weight were edited after the avatar was made: offer a new preview, without replacing anything yet.
    private var measurementsChanged: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoticeRow(tone: .info, text: "Your height or weight changed since this avatar was made. Your current avatar stays until you accept a new one.")
            Button { changeAvatar(.generate) } label: { Label("Generate a New Preview", systemImage: "sparkles") }
                .buttonStyle(FMFilledButtonStyle())
        }
        .fmCard(padding: 14)
    }

    private var accountSection: some View {
        Button(action: openAccount) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.fmCobalt)
                    .frame(width: 36, height: 36)
                    .background(Color.fmTile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Account").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.fmInk)
                    Text(auth.user == nil ? "Sign in or create an account" : (auth.user?.email ?? "Signed in"))
                        .font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.fmSecondary)
            }
            .fmCard(padding: 14)
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("accountButton")
    }

    private var privacy: some View {
        VStack(spacing: 6) {
            Text("Your photos, measurements, and avatar are stored only on this iPhone. Photos are sent to OpenAI only when you choose to generate an avatar.")
                .font(.system(size: 12))
                .foregroundStyle(Color.fmSecondary)
                .multilineTextAlignment(.center)
            if store.profile.setupStarted {
                Button("Delete Avatar and Photos", role: .destructive) { confirmDelete = true }
                    .font(.system(size: 14, weight: .medium))
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

/// A titled card on the Profile page.
private struct AvatarProfileSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.fmInk)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .fmCard(padding: 14)
    }
}

/// Shows a newly picked photo and what the on-device check found, before it replaces the saved one.
struct PhotoConfirmSheet: View {
    var title: String
    var image: UIImage
    var label: String
    var notice: (tone: NoticeRow.Tone, text: String)
    var useLabel: String
    var use: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PhotoPreview(image: image, label: label, notice: notice).padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                Button(useLabel) {
                    use()
                    dismiss()
                }
                .buttonStyle(FMFilledButtonStyle())
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.fmBackground)
            }
            .background(Color.fmBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .preferredColorScheme(.light)
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
                    Text("A cue for your avatar's build").font(.system(size: 12)).foregroundStyle(Color.fmSecondary)
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
