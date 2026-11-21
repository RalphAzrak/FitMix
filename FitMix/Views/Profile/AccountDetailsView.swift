import SwiftUI

/// Edit the display name (Supabase `full_name` metadata) and start an email change through
/// Supabase Auth, which confirms the new address by email when the project requires it.
struct AccountDetailsView: View {
    @Environment(AuthSession.self) private var auth

    @State private var name = ""
    @State private var loaded = false
    @State private var savingName = false
    @State private var nameResult: Result<String, AuthFailure>?

    @State private var newEmail = ""
    @State private var sendingEmail = false
    @State private var emailAttempted = false
    @State private var emailResult: Result<EmailChangeOutcome, AuthFailure>?
    @State private var refreshing = false
    @State private var refreshFailure: String?
    @FocusState private var focus: Field?

    private enum Field { case name, email }

    private var user: AccountUser? { auth.user }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedEmail: String { newEmail.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameChanged: Bool { trimmedName != (user?.fullName ?? "") }

    private var emailError: String? {
        if trimmedEmail.isEmpty { return "Enter your new email." }
        if !AuthForm.looksLikeEmail(trimmedEmail) { return "Enter an email like name@example.com." }
        if trimmedEmail.caseInsensitiveCompare(user?.email ?? "") == .orderedSame { return "That's already your email." }
        return nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("e.g. Alex Morgan"))
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($focus, equals: .name)
                    .onSubmit(saveName)
                    .accessibilityIdentifier("accountName")
                Button(action: saveName) {
                    HStack {
                        Text(savingName ? "Saving…" : "Save Name")
                        if savingName { Spacer(); ProgressView() }
                    }
                }
                .disabled(!nameChanged || trimmedName.isEmpty || savingName)
                .accessibilityIdentifier("accountSaveName")
            } header: {
                Text("Display name")
            } footer: {
                switch nameResult {
                case .success(let saved): Text("Saved. Your profile now shows \(saved).")
                case .failure(let failure): Text("\(failure.message) Tap Save Name to try again.").foregroundStyle(Color.fmError)
                case nil: if trimmedName.isEmpty { Text("Enter a name to save it.") }
                }
            }

            Section {
                LabeledContent("Sign-in email", value: user?.email ?? "—")
                if let pending = user?.pendingEmail {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Waiting for confirmation", systemImage: "envelope.badge")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.fmAmber)
                        Text("We sent a link to \(pending). Your sign-in email changes after it's confirmed.")
                            .font(.footnote)
                            .foregroundStyle(AuthPalette.secondary)
                    }
                    .padding(.vertical, 4)
                    Button(action: refresh) {
                        HStack {
                            Text(refreshing ? "Checking…" : "I've confirmed it")
                            if refreshing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(refreshing)
                }
            } header: {
                Text("Email")
            } footer: {
                if let refreshFailure { Text(refreshFailure).foregroundStyle(Color.fmError) }
                if let notice = auth.emailChangeNotice { Text(notice) }
            }

            Section {
                TextField("New email", text: $newEmail, prompt: Text("you@example.com"))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($focus, equals: .email)
                    .onSubmit(sendEmailChange)
                    .accessibilityIdentifier("accountNewEmail")
                Button(action: sendEmailChange) {
                    HStack {
                        Text(sendingEmail ? "Sending…" : "Send Confirmation Link")
                        if sendingEmail { Spacer(); ProgressView() }
                    }
                }
                .disabled(sendingEmail)
            } header: {
                Text("Change email")
            } footer: {
                emailFooter
            }
        }
        .scrollContentBackground(.hidden)
        .background(AuthPalette.surface.ignoresSafeArea())
        .navigationTitle("Account Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            name = user?.fullName ?? ""
            loaded = true
        }
        .onChange(of: name) { if case .failure = nameResult { nameResult = nil } }
        .onChange(of: newEmail) { if case .failure = emailResult { emailResult = nil } }
        .onDisappear { auth.emailChangeNotice = nil }
    }

    @ViewBuilder
    private var emailFooter: some View {
        if emailAttempted, let emailError {
            Text(emailError).foregroundStyle(Color.fmError)
        } else {
            switch emailResult {
            case .success(.confirmationSent(let address)):
                Text("Check \(address) and open the confirmation link on this iPhone. Depending on your account's security settings, you may also need to confirm from \(user?.email ?? "your current email"). Until then, keep signing in with your current email.")
            case .success(.changed(let address)):
                Text("Your email is now \(address).")
            case .failure(let failure):
                Text("\(failure.message) Tap Send Confirmation Link to try again.").foregroundStyle(Color.fmError)
            case nil:
                Text("We'll email a confirmation link to the new address. Your email doesn't change until it's confirmed.")
            }
        }
    }

    private func saveName() {
        guard nameChanged, !trimmedName.isEmpty, !savingName else { return }
        focus = nil
        savingName = true
        nameResult = nil
        let saved = trimmedName
        Task {
            defer { savingName = false }
            do {
                try await auth.updateDisplayName(saved)
                name = saved
                nameResult = .success(saved)
            } catch {
                nameResult = .failure(AuthFailure(error))
            }
        }
    }

    private func sendEmailChange() {
        emailAttempted = true
        guard emailError == nil, !sendingEmail else { return }
        focus = nil
        sendingEmail = true
        emailResult = nil
        Task {
            defer { sendingEmail = false }
            do {
                emailResult = .success(try await auth.changeEmail(to: trimmedEmail))
                newEmail = ""
                emailAttempted = false
            } catch {
                emailResult = .failure(AuthFailure(error))
            }
        }
    }

    private func refresh() {
        refreshing = true
        refreshFailure = nil
        Task {
            defer { refreshing = false }
            do {
                try await auth.refreshUser()
                if auth.user?.pendingEmail != nil {
                    refreshFailure = "It isn't confirmed yet. Open the link in the email, then check again."
                }
            } catch {
                refreshFailure = AuthFailure(error).message
            }
        }
    }
}
