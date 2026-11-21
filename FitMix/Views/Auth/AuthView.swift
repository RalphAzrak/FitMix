import SwiftUI

/// Sign in / create account. Layout follows the Stitch frame "Sign In & Onboarding".
///
/// Email and password go to Supabase Auth through `AuthSession`, and "Forgot password?" opens
/// the reset request. Apple, Google, help, and the legal links sit where the design puts them but
/// stay disabled until they are wired up. It is not part of the launch flow: it opens from Account on My Avatar.
/// Debug builds can open it with FM_DEBUG_SCREEN=auth or auth-create.
struct AuthView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn, createAccount
        var id: String { rawValue }
        var title: String { self == .signIn ? "Sign In" : "Create Account" }
        var action: String { self == .signIn ? "Sign in" : "Create account" }
    }

    enum Field: Hashable { case name, email, password }

    /// A message under the main button after a request comes back.
    enum Banner: Equatable {
        case failure(String)
        case checkEmail(String)
        case info(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthSession.self) private var auth
    @State private var mode: Mode
    @State private var form = AuthForm()
    @State private var showPassword = false
    /// Errors appear only after the first submit attempt, then update as the user types.
    @State private var attempted = false
    @State private var submitting = false
    @State private var banner: Banner?
    @State private var showForgotPassword = false
    @FocusState private var focus: Field?

    var showsClose: Bool
    /// Called once the user has a session, with the mode they used to get it.
    var onAuthenticated: (Mode) -> Void

    init(mode: Mode = .signIn, showsClose: Bool = true, onAuthenticated: @escaping (Mode) -> Void = { _ in }) {
        _mode = State(initialValue: mode)
        self.showsClose = showsClose
        self.onAuthenticated = onAuthenticated
    }

    private var errors: AuthForm.Errors { form.errors(for: mode) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar.padding(.bottom, 8)
                headline.padding(.top, 8).padding(.bottom, 24)
                FeatureCard().padding(.bottom, 24)
                ModeSwitch(mode: $mode).padding(.bottom, 24).disabled(submitting)
                fields.disabled(submitting)
                submit.padding(.top, 24)
                if let banner {
                    BannerView(banner: banner).padding(.top, 12)
                    if case .checkEmail(let address) = banner {
                        ResendConfirmationButton(email: address).padding(.top, 4)
                    }
                }
                LegalLine().padding(.top, 12)
                FastConnectDivider().padding(.vertical, 24)
                socialButtons
                FooterPill()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AuthPalette.surface.ignoresSafeArea())
        .preferredColorScheme(.light)
        .onChange(of: mode) {
            attempted = false
            // Keep "Check your email" visible after switching to Sign In; clear errors.
            if case .failure = banner { banner = nil }
            if mode == .signIn, focus == .name { focus = .email }
        }
        .onChange(of: form) { if case .failure = banner { banner = nil } }
        .onAppear {
            guard let notice = auth.signInNotice else { return }
            auth.signInNotice = nil
            mode = .signIn
            if let email = notice.email { form.email = email }
            banner = .info(notice.message)
        }
        .fullScreenCover(isPresented: $showForgotPassword) {
            ForgotPasswordView(email: form.email.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .interactiveDismissDisabled(submitting)
    }

    // MARK: Sections

    private var topBar: some View {
        HStack {
            if showsClose {
                CircleIconButton(systemName: "xmark", label: "Close") { dismiss() }
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
            Spacer()
            FitMixWordmark()
                .accessibilityAddTraits(.isHeader)
            Spacer()
            CircleIconButton(systemName: "questionmark.circle", label: "Help") {}
                .disabled(true)
                .accessibilityHint("Not available yet")
        }
        .frame(height: 44)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SPOT · TRY · SHOP")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(AuthPalette.primary)
                .padding(.bottom, 4)
            Text("Your Style Twin Awaits.")
                .font(.system(size: 28, weight: .medium, design: .serif))
                .kerning(-0.3)
                .foregroundStyle(AuthPalette.onSurface)
                .accessibilityAddTraits(.isHeader)
            Text("Spot an outfit you love, find similar pieces, and see how they look on your avatar.")
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(AuthPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mode == .createAccount {
                AuthField(label: "Full Name", icon: "person.text.rectangle", error: attempted ? errors.name : nil) {
                    TextField("", text: $form.name, prompt: prompt("e.g. Alex Morgan"))
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.next)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .email }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            AuthField(label: "Email Address", icon: "envelope", error: attempted ? errors.email : nil) {
                TextField("", text: $form.email, prompt: prompt("you@example.com"))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
            }

            AuthField(label: "Password", icon: "lock", error: attempted ? errors.password : nil) {
                Group {
                    if showPassword {
                        TextField("", text: $form.password, prompt: prompt(passwordPrompt))
                    } else {
                        SecureField("", text: $form.password, prompt: prompt(passwordPrompt))
                    }
                }
                .textContentType(mode == .signIn ? .password : .newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit(submitTapped)
            } accessory: {
                // Kept in place in Create Account so the layout doesn't jump, but hidden there.
                Button("Forgot password?") { showForgotPassword = true }
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(AuthPalette.primary)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                    .opacity(mode == .signIn ? 1 : 0)
                    .disabled(mode != .signIn || submitting)
                    .accessibilityHidden(mode != .signIn)
            } trailing: {
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 17))
                        .foregroundStyle(AuthPalette.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    private func prompt(_ text: String) -> Text {
        Text(text).foregroundStyle(AuthPalette.outline)
    }

    private var passwordPrompt: String {
        mode == .signIn ? "Your password" : "At least \(AuthForm.minPasswordLength) characters"
    }

    private var submit: some View {
        Button(action: submitTapped) {
            HStack(spacing: 8) {
                if submitting {
                    ProgressView().tint(.white)
                    Text(mode == .signIn ? "Signing in…" : "Creating account…")
                } else {
                    Text(mode.action)
                    Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .buttonStyle(AuthPrimaryButtonStyle())
        .disabled(submitting)
    }

    private var socialButtons: some View {
        VStack(spacing: 12) {
            Button {} label: {
                HStack(spacing: 10) {
                    Image(systemName: "apple.logo").font(.system(size: 18)).offset(y: -1)
                    Text("Sign in with Apple")
                }
            }
            .buttonStyle(AuthSocialButtonStyle(background: AuthPalette.onSurface, foreground: AuthPalette.surface))
            .disabled(true)
            .accessibilityHint("Not available yet")

            Button {} label: {
                HStack(spacing: 12) {
                    Text("G")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
                        .accessibilityHidden(true)
                    Text("Continue with Google").fontWeight(.medium)
                }
            }
            .buttonStyle(AuthSocialButtonStyle(background: AuthPalette.containerLow, foreground: AuthPalette.onSurface))
            .disabled(true)
            .accessibilityHint("Not available yet")
        }
    }

    private func submitTapped() {
        attempted = true
        guard errors.isEmpty else {
            focus = errors.firstField
            return
        }
        guard !submitting else { return }
        focus = nil
        banner = nil
        submitting = true
        let mode = mode
        let email = form.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = form.password
        Task {
            defer { submitting = false }
            do {
                switch mode {
                case .signIn:
                    try await auth.signIn(email: email, password: password)
                    onAuthenticated(.signIn)
                case .createAccount:
                    switch try await auth.signUp(fullName: name, email: email, password: password) {
                    case .signedIn:
                        onAuthenticated(.createAccount)
                    case .confirmEmail(let address):
                        // No session until the link is confirmed: move to Sign In with the email filled.
                        form.password = ""
                        form.email = address
                        self.mode = .signIn
                        banner = .checkEmail(address)
                    }
                }
            } catch {
                let failure = AuthFailure(error)
                banner = failure.needsConfirmation ? .checkEmail(email) : .failure(failure.message)
            }
        }
    }
}

// MARK: Form and validation

struct AuthForm: Equatable {
    static let minPasswordLength = 8

    var name = ""
    var email = ""
    var password = ""

    struct Errors {
        var name: String?
        var email: String?
        var password: String?

        var isEmpty: Bool { name == nil && email == nil && password == nil }
        var firstField: AuthView.Field? {
            if name != nil { return .name }
            if email != nil { return .email }
            if password != nil { return .password }
            return nil
        }
    }

    func errors(for mode: AuthView.Mode) -> Errors {
        var result = Errors()
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        if mode == .createAccount, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.name = "Enter your name."
        }

        if trimmedEmail.isEmpty {
            result.email = "Enter your email."
        } else if !Self.looksLikeEmail(trimmedEmail) {
            result.email = "Enter an email like name@example.com."
        }

        if password.isEmpty {
            result.password = "Enter your password."
        } else if mode == .createAccount, password.count < Self.minPasswordLength {
            result.password = "Use at least \(Self.minPasswordLength) characters."
        }
        return result
    }

    /// A light format check: something@something.tld with no spaces.
    static func looksLikeEmail(_ text: String) -> Bool {
        text.wholeMatch(of: #/[^@\s]+@[^@\s]+\.[^@\s]{2,}/#) != nil
    }
}

// MARK: Palette

/// Surface and accent tokens from the Stitch project's theme, used only on this screen.
enum AuthPalette {
    static let surface = Color(hex: 0xFBF9F5)
    static let containerLowest = Color.white
    static let containerLow = Color(hex: 0xF5F3EF)
    static let container = Color(hex: 0xEFEEEA)
    static let containerHigh = Color(hex: 0xEAE8E4)
    static let onSurface = Color(hex: 0x1B1C1A)
    static let secondary = Color(hex: 0x625D5B)
    static let outline = Color(hex: 0x737686)
    static let primary = Color(hex: 0x003FB1)
    static let primaryContainer = Color(hex: 0x1A56DB)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: Components

/// The FitMix logotype shown at the top of the auth and account screens.
struct FitMixWordmark: View {
    var height: CGFloat = 22

    var body: some View {
        Image("Wordmark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("FitMix")
    }
}

struct CircleIconButton: View {
    var systemName: String
    var label: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AuthPalette.onSurface.opacity(isEnabled ? 1 : 0.6))
                .frame(width: 36, height: 36)
                .background(AuthPalette.container, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -4)
        .accessibilityLabel(label)
    }
}

/// What FitMix does, in the card position the design uses for its value preview.
private struct FeatureCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image("AuthGarment")
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 56)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .bottom, endPoint: .top)
                        .frame(height: 16)
                }
                .background(AuthPalette.containerHigh)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(AuthPalette.primaryContainer).frame(width: 6, height: 6)
                    Text("AVATAR TRY-ON")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(AuthPalette.primary)
                }
                Text("Try similar pieces on your avatar")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AuthPalette.onSurface)
                    .lineLimit(1)
                Text("Mix finds from different outfits into one look")
                    .font(.system(size: 11))
                    .foregroundStyle(AuthPalette.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "tshirt")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AuthPalette.onSurface)
                .frame(width: 28, height: 28)
                .background(AuthPalette.container, in: Circle())
                .accessibilityHidden(true)
        }
        .padding(12)
        .background(AuthPalette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .accessibilityElement(children: .combine)
    }
}

/// Two-option switch styled like the frame: white pill on a soft track.
private struct ModeSwitch: View {
    @Binding var mode: AuthView.Mode
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AuthView.Mode.allCases) { option in
                let selected = mode == option
                Button {
                    withAnimation(.snappy(duration: 0.25)) { mode = option }
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? AuthPalette.onSurface : AuthPalette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(AuthPalette.containerLowest)
                                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(AuthPalette.container, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Labelled input row: leading icon, the field, optional label accessory and trailing control, and an error line.
struct AuthField<Input: View, Accessory: View, Trailing: View>: View {
    var label: String
    var icon: String
    var error: String?
    @ViewBuilder var input: Input
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AuthPalette.onSurface)
                    .accessibilityHidden(true)
                Spacer()
                accessory
            }
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(AuthPalette.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                input
                    .font(.system(size: 14))
                    .foregroundStyle(AuthPalette.onSurface)
                    .tint(AuthPalette.primaryContainer)
                    .accessibilityLabel(label)
                trailing
            }
            .padding(.leading, 14)
            .padding(.trailing, Trailing.self == EmptyView.self ? 14 : 4)
            .frame(height: 52)
            .background(AuthPalette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if error != nil {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.fmError, lineWidth: 1.5)
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fmError)
            }
        }
    }
}

extension AuthField where Accessory == EmptyView, Trailing == EmptyView {
    init(label: String, icon: String, error: String?, @ViewBuilder input: () -> Input) {
        self.init(label: label, icon: icon, error: error, input: input, accessory: { EmptyView() }, trailing: { EmptyView() })
    }
}

struct AuthPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .kerning(-0.15)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(AuthPalette.primaryContainer.opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: AuthPalette.primaryContainer.opacity(0.25), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

/// Full-width row for a sign-in provider. Dimmed while the provider isn't connected.
struct AuthSocialButtonStyle: ButtonStyle {
    var background: Color
    var foreground: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.72)
    }
}

/// Terms and privacy links. Both are disabled until the documents exist.
private struct LegalLine: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("By continuing, you agree to the FitMix")
            HStack(spacing: 4) {
                link("Terms")
                Text("&")
                link("Privacy Policy")
                    .padding(.trailing, -4)
                Text(".")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(AuthPalette.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private func link(_ title: String) -> some View {
        Button(title) {}
            .underline()
            .foregroundStyle(AuthPalette.onSurface)
            .disabled(true)
            .accessibilityHint("Not available yet")
    }
}

private struct FastConnectDivider: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(AuthPalette.containerHigh).frame(height: 1)
            Text("OR FAST CONNECT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(AuthPalette.secondary)
                .fixedSize()
            Rectangle().fill(AuthPalette.containerHigh).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Matches what the app does today: avatar captures are kept in the app's container on this iPhone.
private struct FooterPill: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock").font(.system(size: 12))
            Text("Avatar photos and measurements stay on this iPhone")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
        }
        .foregroundStyle(AuthPalette.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AuthPalette.containerHigh.opacity(0.4), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Result of the last request, shown under the main button.
struct BannerView: View {
    var banner: AuthView.Banner

    var body: some View {
        switch banner {
        case .failure(let message):
            NoticeRow(tone: .caution, text: message)
                .accessibilityIdentifier("authError")
        case .checkEmail(let address):
            NoticeCard(icon: "envelope.badge", title: "Check your email",
                       message: "We sent a confirmation link to \(address). Open it on this iPhone to finish signing up. If you confirm on another device, come back and sign in here.")
                .accessibilityIdentifier("checkEmail")
        case .info(let message):
            NoticeCard(icon: "checkmark.circle", title: message, message: nil)
                .accessibilityIdentifier("authInfo")
        }
    }
}

/// Soft card with a cobalt icon, for "check your email" and other good news.
struct NoticeCard: View {
    var icon: String
    var title: String
    var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(AuthPalette.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AuthPalette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(AuthPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AuthPalette.containerLow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AuthPalette.primary.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Account

/// What Account opens: an opened reset or confirmation link, else Profile when signed in, or the sign-in forms.
struct AccountFlowView: View {
    var mode: AuthView.Mode = .signIn
    var onAuthenticated: (AuthView.Mode) -> Void = { _ in }
    @Environment(AuthSession.self) private var auth

    var body: some View {
        if let recovery = auth.recovery {
            ResetPasswordView(recovery: recovery)
        } else if let confirmation = auth.confirmation {
            // A confirmation link that signed in continues like a finished sign-up.
            EmailConfirmationView(confirmation: confirmation) { onAuthenticated(.createAccount) }
        } else {
            accountOrSignIn
        }
    }

    @ViewBuilder
    private var accountOrSignIn: some View {
        switch auth.state {
        case .signedIn:
            ProfileView()
        case .signedOut:
            AuthView(mode: mode, onAuthenticated: onAuthenticated)
        case .restoring:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AuthPalette.surface.ignoresSafeArea())
        }
    }
}

#Preview("Sign In") {
    AuthView(mode: .signIn).environment(AuthSession())
}

#Preview("Create Account") {
    AuthView(mode: .createAccount).environment(AuthSession())
}
