import SwiftUI

/// Opened by the link in a sign-up confirmation email (fitmix://confirm-email).
struct EmailConfirmationView: View {
    var confirmation: AuthSession.Confirmation
    /// Called when a confirmed link also signed the user in and they continue into FitMix.
    var onContinue: () -> Void
    @Environment(AuthSession.self) private var auth

    var body: some View {
        switch confirmation {
        case .verifying:
            AuthScreen(eyebrow: "EMAIL CONFIRMATION", title: "Confirming your email",
                       subtitle: "Checking your link…", close: backToSignIn) {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
            }
        case .verified(let email):
            AuthScreen(eyebrow: "EMAIL CONFIRMATION", title: "Email verified",
                       subtitle: email.map { "You're signed in as \($0). Your FitMix account is ready." }
                           ?? "You're signed in. Your FitMix account is ready.",
                       close: onContinue) {
                Button(action: onContinue) {
                    HStack(spacing: 8) {
                        Text("Continue to FitMix")
                        Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold))
                    }
                }
                .buttonStyle(AuthPrimaryButtonStyle())
                .accessibilityIdentifier("confirmContinue")
            }
        case .unconfirmed(let email, let reason):
            AuthScreen(eyebrow: "EMAIL CONFIRMATION", title: Self.title(for: reason),
                       subtitle: Self.subtitle(for: reason), close: backToSignIn) {
                Button(action: backToSignIn) {
                    HStack(spacing: 8) {
                        Text("Go to Sign In")
                        Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold))
                    }
                }
                .buttonStyle(AuthPrimaryButtonStyle())
                .accessibilityIdentifier("confirmSignIn")
                ResendConfirmationForm(email: email ?? "").padding(.top, 32)
            }
        }
    }

    static func title(for reason: AuthSession.Confirmation.Reason) -> String {
        switch reason {
        case .linkRejected: "This link didn't work"
        case .notConfirmedHere: "Let's finish on Sign In"
        }
    }

    static func subtitle(for reason: AuthSession.Confirmation.Reason) -> String {
        switch reason {
        case .linkRejected:
            "This confirmation link has expired or was already used. Try signing in. If FitMix says your email still needs confirming, send yourself a new link."
        case .notConfirmedHere:
            "FitMix couldn't complete this link on this iPhone. This can happen if it was opened on another device. Try signing in. If FitMix says your email still needs confirming, send yourself a new link."
        }
    }

    private func backToSignIn() { auth.finishConfirmation() }
}

/// Email field and "Resend confirmation email", for a link FitMix couldn't confirm.
private struct ResendConfirmationForm: View {
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
                    .accessibilityIdentifier("resendEmail")
                    .onSubmit(send)
            }
            .disabled(sending)

            Button(action: send) {
                HStack(spacing: 8) {
                    if sending {
                        ProgressView().tint(.white)
                        Text("Sending…")
                    } else {
                        Text(sentTo == nil ? "Resend confirmation email" : "Send another email")
                    }
                }
            }
            .buttonStyle(AuthSocialButtonStyle(background: AuthPalette.containerLow, foreground: AuthPalette.onSurface))
            .disabled(sending)
            .padding(.top, 24)

            if let sentTo {
                NoticeCard(icon: "envelope.badge", title: "Check your email",
                           message: ResendConfirmationButton.sentMessage(sentTo))
                    .accessibilityIdentifier("resendSent")
                    .padding(.top, 12)
            }
            if let failure {
                NoticeRow(tone: .caution, text: failure)
                    .accessibilityIdentifier("resendError")
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
                try await auth.resendConfirmation(email: address)
                sentTo = address
            } catch {
                failure = AuthFailure(error).message
            }
        }
    }
}

/// "Enter the code" under the "Check your email" card, so sign-up can finish without leaving
/// FitMix when a mail app won't hand the link back.
struct ConfirmationCodeForm: View {
    var email: String
    /// Called once Supabase has confirmed the email and signed the user in.
    var onVerified: () -> Void
    @Environment(AuthSession.self) private var auth
    @State private var code = ""
    @State private var verifying = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    /// Supabase's email code is 6 digits by default; the project can set up to 10.
    private var digits: String { code.filter(\.isNumber) }
    private var looksComplete: Bool { (6...10).contains(digits.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AuthField(label: "Confirmation Code", icon: "number", error: failure) {
                TextField("", text: $code, prompt: Text("Code from the email").foregroundStyle(AuthPalette.outline))
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .accessibilityIdentifier("confirmCode")
            }
            .disabled(verifying)

            Button(action: verify) {
                HStack(spacing: 8) {
                    if verifying {
                        ProgressView().tint(.white)
                        Text("Verifying…")
                    } else {
                        Text("Verify")
                        Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            .buttonStyle(AuthPrimaryButtonStyle())
            .disabled(verifying || !looksComplete)
            .opacity(looksComplete || verifying ? 1 : 0.5)
            .accessibilityIdentifier("confirmCodeVerify")
            .padding(.top, 16)
        }
        .onChange(of: code) {
            failure = nil
            if code != digits { code = digits }
        }
        .onChange(of: email) {
            code = ""
            failure = nil
        }
    }

    private func verify() {
        guard looksComplete, !verifying else { return }
        focused = false
        failure = nil
        verifying = true
        let token = digits
        Task {
            defer { verifying = false }
            do {
                try await auth.verifySignupCode(email: email, code: token)
                onVerified()
            } catch {
                failure = AuthFailure(error).message
            }
        }
    }
}

/// "Resend email" under the "Check your email" card on Sign In / Create Account.
struct ResendConfirmationButton: View {
    var email: String
    @Environment(AuthSession.self) private var auth
    @State private var sending = false
    @State private var sent = false
    @State private var failure: String?

    static func sentMessage(_ email: String) -> String {
        "If \(email) still needs confirming, we sent a new link. Open the newest email on this iPhone. Already confirmed? Sign in."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                send()
            } label: {
                HStack(spacing: 6) {
                    if sending { ProgressView().controlSize(.small) }
                    Text(sending ? "Sending…" : sent ? "Send another link" : "Didn't get it? Resend email")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AuthPalette.primary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(sending)
            .accessibilityIdentifier("resendConfirmation")

            if sent {
                Text(Self.sentMessage(email))
                    .font(.system(size: 13))
                    .foregroundStyle(AuthPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("resendSent")
            }
            if let failure {
                NoticeRow(tone: .caution, text: failure).accessibilityIdentifier("resendError")
            }
        }
        .onChange(of: email) {
            sent = false
            failure = nil
        }
    }

    private func send() {
        guard !sending else { return }
        sending = true
        failure = nil
        Task {
            defer { sending = false }
            do {
                try await auth.resendConfirmation(email: email)
                sent = true
            } catch {
                failure = AuthFailure(error).message
            }
        }
    }
}

#Preview("Verified") {
    EmailConfirmationView(confirmation: .verified(email: "alex@example.com"), onContinue: {})
        .environment(AuthSession())
}

#Preview("Not confirmed here") {
    EmailConfirmationView(confirmation: .unconfirmed(email: nil, reason: .notConfirmedHere), onContinue: {})
        .environment(AuthSession())
}

#Preview("Link rejected") {
    EmailConfirmationView(confirmation: .unconfirmed(email: "alex@example.com", reason: .linkRejected), onContinue: {})
        .environment(AuthSession())
}
