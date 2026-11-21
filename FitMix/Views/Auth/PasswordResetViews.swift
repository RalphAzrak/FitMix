import SwiftUI

/// Shared frame for the password and email-confirmation screens: wordmark header, eyebrow, serif title, subtitle.
struct AuthScreen<Content: View>: View {
    var eyebrow: String
    var title: String
    var subtitle: String
    var closeLabel = "Close"
    var close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    CircleIconButton(systemName: "xmark", label: closeLabel, action: close)
                    Spacer()
                    FitMixWordmark()
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .frame(height: 44)
                .padding(.bottom, 16)

                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(AuthPalette.primary)
                    .padding(.bottom, 4)
                Text(title)
                    .font(.fmDisplay(28))
                    .kerning(-0.3)
                    .foregroundStyle(AuthPalette.onSurface)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.bottom, 24)

                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AuthPalette.surface.ignoresSafeArea())
        .preferredColorScheme(.light)
    }
}

// MARK: Request a reset link

/// Email field and "Send reset link". Shows the same confirmation whether or not the email has an account.
private struct ResetRequestForm: View {
    @Environment(AuthSession.self) private var auth
    @State var email: String
    @State private var attempted = false
    @State private var sending = false
    @State private var sentTo: String?
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var emailError: String? {
        if trimmed.isEmpty { return "Enter your email." }
        if !AuthForm.looksLikeEmail(trimmed) { return "Enter an email like name@example.com." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuthField(label: "Email Address", icon: "envelope", error: attempted ? emailError : nil) {
                TextField("", text: $email, prompt: Text("you@example.com").foregroundStyle(AuthPalette.outline))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($focused)
                    .accessibilityIdentifier("resetEmail")
                    .onSubmit(send)
            }
            .disabled(sending)

            Button(action: send) {
                HStack(spacing: 8) {
                    if sending {
                        ProgressView().tint(.white)
                        Text("Sending…")
                    } else {
                        Text(sentTo == nil ? "Send reset link" : "Send another link")
                        Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            .buttonStyle(AuthPrimaryButtonStyle())
            .disabled(sending)
            .padding(.top, 24)

            if let sentTo {
                NoticeCard(icon: "envelope.badge", title: "Check your email",
                           message: "If an account exists for \(sentTo), we sent a link to reset your password. Open it on this iPhone. It can take a minute to arrive.")
                    .accessibilityIdentifier("resetSent")
                    .padding(.top, 12)
            }
            if let failure {
                NoticeRow(tone: .caution, text: failure)
                    .accessibilityIdentifier("resetError")
                    .padding(.top, 12)
            }
        }
        .onChange(of: email) { failure = nil }
    }

    private func send() {
        attempted = true
        guard emailError == nil, !sending else { return }
        focused = false
        failure = nil
        sending = true
        let address = trimmed
        Task {
            defer { sending = false }
            do {
                try await auth.requestPasswordReset(email: address)
                sentTo = address
            } catch {
                failure = AuthFailure(error).message
            }
        }
    }
}

/// Opened from "Forgot password?" on Sign In.
struct ForgotPasswordView: View {
    var email: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AuthScreen(eyebrow: "PASSWORD RESET",
                   title: "Forgot your password?",
                   subtitle: "Enter the email you use for FitMix and we'll send you a link to set a new password.",
                   closeLabel: "Back to Sign In",
                   close: { dismiss() }) {
            ResetRequestForm(email: email)
        }
    }
}

// MARK: Set a new password

/// Opened by the link in a password-reset email.
struct ResetPasswordView: View {
    var recovery: AuthSession.Recovery
    @Environment(AuthSession.self) private var auth

    var body: some View {
        switch recovery {
        case .verifying:
            AuthScreen(eyebrow: "PASSWORD RESET", title: "Set a new password",
                       subtitle: "Checking your reset link…", close: cancel) {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
            }
        case .ready(let email):
            AuthScreen(eyebrow: "PASSWORD RESET", title: "Set a new password",
                       subtitle: email.map { "Choose a new password for \($0)." } ?? "Choose a new password for your account.",
                       close: cancel) {
                NewPasswordForm()
            }
        case .invalid(let message):
            AuthScreen(eyebrow: "PASSWORD RESET", title: "This link didn't work",
                       subtitle: message, close: cancel) {
                ResetRequestForm(email: "")
                Button("Back to Sign In", action: cancel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AuthPalette.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.top, 12)
            }
        }
    }

    private func cancel() {
        Task { await auth.finishRecovery(notice: nil) }
    }
}

private struct NewPasswordForm: View {
    enum Field: Hashable { case password, confirm }

    @Environment(AuthSession.self) private var auth
    @State private var password = ""
    @State private var confirm = ""
    @State private var showPassword = false
    @State private var attempted = false
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focus: Field?

    private var passwordError: String? {
        if password.isEmpty { return "Enter a new password." }
        if password.count < AuthForm.minPasswordLength { return "Use at least \(AuthForm.minPasswordLength) characters." }
        return nil
    }

    private var confirmError: String? {
        if confirm.isEmpty { return "Enter the password again." }
        if confirm != password { return "The passwords don't match." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                AuthField(label: "New Password", icon: "lock", error: attempted ? passwordError : nil) {
                    secure($password, prompt: "At least \(AuthForm.minPasswordLength) characters")
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focus = .confirm }
                } accessory: {
                    EmptyView()
                } trailing: {
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .font(.system(size: 17))
                            .foregroundStyle(AuthPalette.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }

                AuthField(label: "Confirm Password", icon: "lock.rotation", error: attempted ? confirmError : nil) {
                    secure($confirm, prompt: "Type it again")
                        .focused($focus, equals: .confirm)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
            }
            .disabled(saving)

            Button(action: save) {
                HStack(spacing: 8) {
                    if saving {
                        ProgressView().tint(.white)
                        Text("Updating…")
                    } else {
                        Text("Update password")
                        Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            .buttonStyle(AuthPrimaryButtonStyle())
            .disabled(saving)
            .padding(.top, 24)

            if let failure {
                NoticeRow(tone: .caution, text: failure)
                    .accessibilityIdentifier("resetError")
                    .padding(.top, 12)
            }
        }
        .onChange(of: password) { failure = nil }
        .onChange(of: confirm) { failure = nil }
    }

    @ViewBuilder
    private func secure(_ text: Binding<String>, prompt: String) -> some View {
        Group {
            if showPassword {
                TextField("", text: text, prompt: Text(prompt).foregroundStyle(AuthPalette.outline))
            } else {
                SecureField("", text: text, prompt: Text(prompt).foregroundStyle(AuthPalette.outline))
            }
        }
        .textContentType(.newPassword)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func save() {
        attempted = true
        guard passwordError == nil, confirmError == nil, !saving else {
            focus = passwordError != nil ? .password : .confirm
            return
        }
        focus = nil
        failure = nil
        saving = true
        let newPassword = password
        Task {
            defer { saving = false }
            do {
                try await auth.updatePassword(newPassword)
                await auth.finishRecovery(notice: .init(email: nil, message: "Password updated. Sign in with your new password."))
            } catch {
                failure = AuthFailure(error).message
            }
        }
    }
}

#Preview("Forgot password") {
    ForgotPasswordView(email: "you@example.com").environment(AuthSession())
}

#Preview("Invalid link") {
    ResetPasswordView(recovery: .invalid("This reset link has expired or was already used. Request a new one below."))
        .environment(AuthSession())
}
