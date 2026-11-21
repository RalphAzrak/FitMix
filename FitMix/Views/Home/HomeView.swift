import SwiftUI
import UIKit

/// The My Avatar home screen.
struct HomeView: View {
    @Environment(AvatarStore.self) private var store

    /// The step the creation flow is open at, or `nil` when it is closed.
    @State private var flow: SetupStep?
    @State private var showMetricsEditor = false
    @State private var placeholder: PlaceholderScreen?
    @State private var confirmDelete = false
    @State private var authPreview: AuthView.Mode?
    /// Set when sign-in or sign-up finishes and there is no avatar yet; opens the creation flow once Account closes.
    @State private var setupAfterAuth = false
    @Environment(AuthSession.self) private var auth

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                StatusCard(state: store.homeState, profile: store.profile)
                primaryButton
                AvatarPortraitCard(makeNew: { flow = .bodyPhoto })
                if store.homeState == .ready, store.profile.measurementsChangedSinceAvatar { measurementsChanged }
                SourceReferenceCard(change: { flow = .bodyPhoto })
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
        .fullScreenCover(item: $flow) { SetupFlowView(startAt: $0) }
        .fullScreenCover(item: $placeholder) { PlaceholderView(screen: $0) }
        .fullScreenCover(item: $authPreview, onDismiss: {
            if setupAfterAuth {
                setupAfterAuth = false
                flow = store.resumeStep
            }
        }) { mode in
            AccountFlowView(mode: mode) { _ in
                setupAfterAuth = store.profile.avatar == nil && store.profile.candidate == nil
                authPreview = nil
            }
        }
        .sheet(isPresented: $showMetricsEditor) { MetricsEditorSheet() }
        .confirmationDialog("Delete your avatar?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Avatar and Photos", role: .destructive) { store.deleteEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your avatar, full-body photo, selfie, and measurements from this iPhone. It can't be undone.")
        }
        .alert("Couldn't save", isPresented: Binding(get: { store.storageErrorMessage != nil && flow == nil },
                                                    set: { if !$0 { store.storageErrorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.storageErrorMessage ?? "")
        }
        .onAppear {
            switch Self.debugScreen {
            case "setup": flow = store.resumeStep
            case "generate": flow = .generate
            case "metrics": showMetricsEditor = true
            case "auth": authPreview = .signIn
            case "auth-create": authPreview = .createAccount
            default: break
            }
        }
    }

    /// Debug builds can open straight into a screen with FM_DEBUG_SCREEN=setup | generate | metrics | auth | auth-create | bottom.
    private static var debugScreen: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["FM_DEBUG_SCREEN"]
        #else
        nil
        #endif
    }

    private var header: some View {
        HStack(alignment: .top) {
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
            Spacer(minLength: 12)
            Button { authPreview = .signIn } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.fmInk)
                    .frame(width: 44, height: 44)
                    .background(Color.fmCard, in: Circle())
                    .overlay(Circle().strokeBorder(Color.fmHairline))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Account")
            .accessibilityValue(auth.user == nil ? "Signed out" : "Signed in")
            .accessibilityIdentifier("accountButton")
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch store.homeState {
        case .empty:
            Button { flow = .bodyPhoto } label: { Label("Create My Avatar", systemImage: "person.crop.circle.badge.plus") }
                .buttonStyle(FMFilledButtonStyle())
        case .setupInProgress:
            Button { flow = store.resumeStep } label: { Label("Continue Setup", systemImage: "arrow.right.circle") }
                .buttonStyle(FMFilledButtonStyle())
        case .reviewPending:
            Button { flow = .review } label: { Label("Review New Avatar", systemImage: "eye") }
                .buttonStyle(FMFilledButtonStyle())
        case .generating:
            Button { flow = .generate } label: { Label("View Progress", systemImage: "hourglass") }
                .buttonStyle(FMOutlineButtonStyle())
        case .error:
            Button { flow = .generate } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                .buttonStyle(FMFilledButtonStyle())
        case .ready:
            EmptyView()
        }
    }

    /// Height or weight were edited after the avatar was made: offer a new preview, without replacing anything yet.
    private var measurementsChanged: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoticeRow(tone: .info, text: "Your height or weight changed since this avatar was made. Your current avatar stays until you accept a new one.")
            Button { flow = .generate } label: { Label("Generate a New Preview", systemImage: "sparkles") }
                .buttonStyle(FMFilledButtonStyle())
        }
        .fmCard(padding: 14)
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
    }
}

// MARK: Status

struct StatusCard: View {
    var state: HomeState
    var profile: AvatarProfile

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
        case .empty: "Create your avatar"
        case .setupInProgress: "Finish your avatar"
        case .generating: "Creating your avatar…"
        case .reviewPending: "New avatar ready to review"
        case .ready: "Avatar ready"
        case .error: "Your avatar couldn't be created"
        }
    }

    private var detail: String {
        switch state {
        case .empty: "Add a full-body photo, an optional selfie, and your height and weight."
        case .setupInProgress:
            profile.hasBodyPhoto && profile.hasMetrics ? "Your saved full-body photo and measurements are ready to reuse."
                : (profile.hasBodyPhoto ? "Your saved full-body photo is ready to reuse." : "Your progress is saved. Pick up where you left off.")
        case .generating: "This usually takes a minute or two. Keep FitMix open."
        case .reviewPending: profile.avatar == nil ? "Accept it to make it your avatar." : "Your current avatar stays until you accept the new one."
        case .ready: "An AI-generated illustration and an approximate likeness. It can't predict clothing size or fit."
        case .error(let message): message
        }
    }

    private var icon: String {
        switch state {
        case .empty, .setupInProgress: "person.fill"
        case .generating: "hourglass"
        case .reviewPending: "eye"
        case .ready: "checkmark"
        case .error: "exclamationmark"
        }
    }

    private var iconBackground: Color {
        switch state {
        case .ready, .generating, .reviewPending: .fmCobalt
        case .error: .fmAmber
        case .empty, .setupInProgress: .fmCharcoal
        }
    }
}

// MARK: Avatar portrait

/// The accepted avatar: a still, full-body portrait. Shows a placeholder until there is one.
struct AvatarPortraitCard: View {
    var makeNew: () -> Void
    @Environment(AvatarStore.self) private var store

    var body: some View {
        let record = store.profile.avatar
        VStack(spacing: 0) {
            HStack {
                Eyebrow(text: "Studio preview", color: .white.opacity(0.6))
                Spacer()
                Text(record == nil ? "No avatar yet" : "AI-generated")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .frame(minHeight: 22)
                    .background(.white.opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ZStack {
                Color.fmStudio
                if let portrait = store.avatarImage {
                    Image(uiImage: portrait)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity)
                        .accessibilityLabel("Your avatar: a full-body animated-style portrait")
                } else if record != nil {
                    ProgressView().controlSize(.large).accessibilityLabel("Loading your avatar")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "figure.stand").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Color.fmSecondary.opacity(0.6))
                        Text("Your avatar will appear here").font(.system(size: 14)).foregroundStyle(Color.fmSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .animation(.easeOut(duration: 0.25), value: store.avatarImage == nil)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 10)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record == nil ? "No avatar yet" : "Animated-style portrait")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(record.map { Self.madeFrom($0, units: store.profile.units) } ?? "Made from your photos when you choose to generate.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if record != nil {
                    Button(action: makeNew) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .accessibilityLabel("Make a new avatar")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.fmCharcoal, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Says what a portrait was actually made from.
    static func madeFrom(_ record: AvatarRecord, units: UnitSystem) -> String {
        let photos = record.usedSelfie ? "your full-body photo and selfie" : "your full-body photo"
        return "Made from \(photos), \(BodyMeasurements.heightText(cm: record.heightCm, units: units)) and \(BodyMeasurements.weightText(kg: record.weightKg, units: units))."
    }
}

// MARK: Source photos

struct SourceReferenceCard: View {
    var change: () -> Void
    @Environment(AvatarStore.self) private var store

    var body: some View {
        let profile = store.profile
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Source Photos").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.fmInk)
                Spacer()
                Button(action: change) {
                    Label(profile.hasBodyPhoto ? "Change photos" : "Add photo", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13, weight: .semibold))
                }
                .tint(Color.fmCobalt)
                .frame(minHeight: 44)
            }
            HStack(spacing: 12) {
                thumbnail(store.bodyThumbnail, icon: "figure.stand")
                if profile.hasSelfie { thumbnail(store.selfie, icon: "face.smiling") }
                VStack(alignment: .leading, spacing: 4) {
                    if profile.hasBodyPhoto {
                        let notice = profile.photoAnalysis.notice
                        Text(profile.hasSelfie ? "Full-body photo and selfie" : "Full-body photo")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmInk)
                        NoticeRow(tone: notice.tone, text: notice.text).font(.system(size: 13))
                        if !profile.hasSelfie {
                            Text("No selfie added.").font(.system(size: 13)).foregroundStyle(Color.fmSecondary)
                        }
                    } else {
                        Text("No full-body photo yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.fmInk)
                        Text("Stand facing the camera with your whole body visible, head to shoes.")
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

    private func thumbnail(_ image: UIImage?, icon: String) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: icon).font(.system(size: 24)).foregroundStyle(Color.fmSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: image == nil)
        .frame(width: 54, height: 72)
        .background(Color.fmCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
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
