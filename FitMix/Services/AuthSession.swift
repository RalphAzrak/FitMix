import Foundation
import Supabase

/// Supabase project settings. The publishable key is meant to ship in client apps;
/// access to data is controlled by the project's row-level security, not by this key.
enum SupabaseConfig {
    static let url = URL(string: "https://hdxpakrlayubyhagbrrw.supabase.co")!
    static let publishableKey = "sb_publishable_brDJuQaIYtYr9rxy-e8R7w_fqdC63Cv"
    /// Where password-reset emails send people. Must be listed in Supabase → Authentication →
    /// URL Configuration → Redirect URLs, and matches the `fitmix` URL scheme in Config/Info.plist.
    static let passwordResetRedirect = URL(string: "fitmix://reset-password")!
    /// Where email-change confirmation links send people. Add it to the same Redirect URLs list;
    /// if it isn't listed, Supabase falls back to the Site URL and the change still completes.
    static let emailChangeRedirect = URL(string: "fitmix://email-change")!
}

/// The signed-in FitMix account, as shown in the app.
struct AccountUser: Equatable {
    var id: UUID
    var email: String?
    var fullName: String?
    /// A new email address waiting for its confirmation link to be opened.
    var pendingEmail: String?

    init(_ user: User) {
        id = user.id
        email = user.email
        fullName = user.userMetadata["full_name"]?.stringValue
        pendingEmail = user.newEmail.flatMap { $0.isEmpty || $0 == user.email ? nil : $0 }
    }

    init(id: UUID, email: String?, fullName: String?, pendingEmail: String? = nil) {
        self.id = id
        self.email = email
        self.fullName = fullName
        self.pendingEmail = pendingEmail
    }

    /// The name to show: the saved full name, else the part of the email before the @.
    var displayName: String {
        if let fullName, !fullName.trimmingCharacters(in: .whitespaces).isEmpty { return fullName }
        return email.map { String($0.prefix { $0 != "@" }) } ?? "FitMix member"
    }

    /// Up to two initials for the account badge, e.g. "AM" for "Alex Morgan".
    var initials: String {
        if let name = fullName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        }
        return email?.first.map { String($0).uppercased() } ?? "?"
    }
}

/// What happened after asking to change the account email.
enum EmailChangeOutcome: Equatable {
    /// The project doesn't require confirmation: the email is already changed.
    case changed(String)
    /// A confirmation link was sent. The sign-in email stays the same until it's opened.
    case confirmationSent(String)
}

/// Owns the Supabase auth session. The SDK keeps the session in the Keychain and refreshes
/// it automatically, so a signed-in user stays signed in across relaunches.
@Observable
final class AuthSession {
    enum State: Equatable {
        /// Still reading the saved session at launch.
        case restoring
        case signedOut
        case signedIn(AccountUser)
    }

    enum SignUpOutcome: Equatable {
        case signedIn
        /// The project requires email confirmation: no session until the user confirms.
        case confirmEmail(String)
    }

    /// A password-reset link that has been opened, from checking it to setting the new password.
    enum Recovery: Equatable {
        case verifying
        /// The link worked: the user has a short recovery session and can set a new password.
        case ready(email: String?)
        /// The link was expired, already used, or opened somewhere it can't be completed.
        case invalid(String)
    }

    /// Shown on Sign In the next time it appears, e.g. after a password change.
    struct SignInNotice: Equatable {
        var email: String?
        var message: String
    }

    private(set) var state: State = .restoring
    private(set) var recovery: Recovery?
    var signInNotice: SignInNotice?
    /// Set after an email-change confirmation link is opened, for Account details to show.
    var emailChangeNotice: String?

    var user: AccountUser? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    @ObservationIgnored private let client: SupabaseClient
    @ObservationIgnored private var listener: Task<Void, Never>?

    init() {
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.publishableKey,
            options: SupabaseClientOptions(auth: .init(
                storage: KeychainLocalStorage(),
                emitLocalSessionAsInitialSession: true
            ))
        )
        #if DEBUG
        // Debug builds only: FM_DEBUG_ACCOUNT_ID signs in a local stand-in account without Supabase,
        // so Profile can be checked in the simulator. Requests that need the server will fail.
        if let account = Self.debugAccount {
            state = .signedIn(account)
            return
        }
        #endif
        listener = Task { [weak self, client] in
            for await (event, session) in client.auth.authStateChanges {
                guard let self else { return }
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    state = session.map { .signedIn(AccountUser($0.user)) } ?? .signedOut
                case .signedOut:
                    state = .signedOut
                default:
                    break
                }
            }
        }
    }

    deinit { listener?.cancel() }

    func signIn(email: String, password: String) async throws {
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            state = .signedIn(AccountUser(session.user))
        } catch {
            throw AuthFailure(error)
        }
    }

    // MARK: Account details

    /// Saves the display name to the account's `full_name` metadata, the same field sign-up sets.
    func updateDisplayName(_ name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let user = try await client.auth.update(user: UserAttributes(data: ["full_name": .string(name)]))
            state = .signedIn(AccountUser(user))
        } catch {
            throw AuthFailure(error)
        }
    }

    /// Starts an email change through Supabase Auth. When the project requires confirmation (the
    /// default), Supabase emails a link and the sign-in email changes only once it's opened.
    func changeEmail(to email: String) async throws -> EmailChangeOutcome {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let user = try await client.auth.update(user: UserAttributes(email: email),
                                                    redirectTo: SupabaseConfig.emailChangeRedirect)
            state = .signedIn(AccountUser(user))
            if user.email?.caseInsensitiveCompare(email) == .orderedSame { return .changed(email) }
            return .confirmationSent(email)
        } catch let error as AuthError where [.emailExists, .userAlreadyExists].contains(error.errorCode) {
            throw AuthFailure(message: "Another account already uses this email.")
        } catch {
            throw AuthFailure(error)
        }
    }

    /// Fetches the latest account details from Supabase, e.g. after an email change was confirmed
    /// in a browser.
    func refreshUser() async throws {
        guard user != nil else { return }
        do {
            state = .signedIn(AccountUser(try await client.auth.user()))
        } catch {
            throw AuthFailure(error)
        }
    }

    func signUp(fullName: String, email: String, password: String) async throws -> SignUpOutcome {
        do {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["full_name": .string(fullName)]
            )
            switch response {
            case .session(let session):
                state = .signedIn(AccountUser(session.user))
                return .signedIn
            case .user:
                return .confirmEmail(email)
            }
        } catch {
            throw AuthFailure(error)
        }
    }

    // MARK: Password reset

    /// Asks Supabase to email a reset link. Succeeds the same way whether or not the email has an
    /// account, so the screen never reveals which addresses are registered.
    func requestPasswordReset(email: String) async throws {
        do {
            try await client.auth.resetPasswordForEmail(email, redirectTo: SupabaseConfig.passwordResetRedirect)
        } catch let error as AuthError where [.userNotFound, .overEmailSendRateLimit, .emailAddressNotAuthorized].contains(error.errorCode) {
            // Treated like success: these can depend on whether the address has an account.
        } catch {
            throw AuthFailure(error)
        }
    }

    /// Opens a link from a password-reset email. Returns false for URLs that aren't reset links.
    @discardableResult
    func handle(url: URL) -> Bool {
        if url.scheme == SupabaseConfig.emailChangeRedirect.scheme, url.host == SupabaseConfig.emailChangeRedirect.host {
            handleEmailChange(url: url)
            return true
        }
        guard url.scheme == SupabaseConfig.passwordResetRedirect.scheme,
              url.host == SupabaseConfig.passwordResetRedirect.host else { return false }
        recovery = .verifying
        Task {
            do {
                let session = try await client.auth.session(from: url)
                recovery = .ready(email: session.user.email)
            } catch {
                recovery = .invalid(Self.recoveryLinkMessage(for: error))
            }
        }
        return true
    }

    func updatePassword(_ password: String) async throws {
        do {
            _ = try await client.auth.update(user: UserAttributes(password: password))
        } catch {
            throw AuthFailure(error)
        }
    }

    /// Ends recovery: signs out of the recovery session and goes back to Sign In.
    func finishRecovery(notice: SignInNotice?) async {
        let email: String? = if case .ready(let email) = recovery { email } else { nil }
        if user != nil {
            try? await client.auth.signOut(scope: .local)
            state = .signedOut
        }
        signInNotice = notice.map { SignInNotice(email: $0.email ?? email, message: $0.message) }
        recovery = nil
    }

    private func handleEmailChange(url: URL) {
        Task {
            // The link may carry a new session (PKCE code or tokens). Either way, re-read the user.
            _ = try? await client.auth.session(from: url)
            try? await refreshUser()
            if let user {
                emailChangeNotice = user.pendingEmail == nil
                    ? "Your email is now \(user.email ?? "updated")."
                    : "Confirmation received. Open the link sent to your other address to finish changing your email."
            }
        }
    }

    #if DEBUG
    private static var debugAccount: AccountUser? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["FM_DEBUG_ACCOUNT_ID"], let id = UUID(uuidString: raw) else { return nil }
        return AccountUser(id: id, email: env["FM_DEBUG_ACCOUNT_EMAIL"] ?? "test@example.com",
                           fullName: env["FM_DEBUG_ACCOUNT_NAME"])
    }
    #endif

    private static func recoveryLinkMessage(for error: Error) -> String {
        guard let auth = error as? AuthError else {
            return (error as? URLError) != nil
                ? "FitMix couldn't reach the server to check this link. Request a new one and try again."
                : "This reset link didn't work. Request a new one below."
        }
        if case .pkceGrantCodeExchange(_, _, let code) = auth, code == ErrorCode.otpExpired.rawValue {
            return "This reset link has expired or was already used. Request a new one below."
        }
        switch auth.errorCode {
        case .otpExpired, .flowStateExpired, .flowStateNotFound:
            return "This reset link has expired or was already used. Request a new one below."
        case .badCodeVerifier:
            return "Open the reset link on the same iPhone where you requested it, or request a new one below."
        default:
            if case .pkceGrantCodeExchange(let message, _, _) = auth, message.contains("code verifier") {
                return "Open the reset link on the same iPhone where you requested it, or request a new one below."
            }
            return "This reset link didn't work. Request a new one below."
        }
    }

    func signOut() async throws {
        do {
            try await client.auth.signOut()
        } catch let error as AuthError where error.errorCode == .sessionNotFound {
            // Already gone on the server; the SDK has cleared the local copy.
        } catch {
            // Still sign out on this device, even if the server couldn't be reached.
            try? await client.auth.signOut(scope: .local)
            if user != nil { throw AuthFailure(error) }
        }
        state = .signedOut
    }
}

/// A user-facing reason an auth request failed.
struct AuthFailure: LocalizedError, Equatable {
    var message: String
    /// True when the account exists but its email hasn't been confirmed.
    var needsConfirmation = false

    var errorDescription: String? { message }

    init(message: String, needsConfirmation: Bool = false) {
        self.message = message
        self.needsConfirmation = needsConfirmation
    }

    init(_ error: Error) {
        if let failure = error as? AuthFailure { self = failure; return }
        if let urlError = error as? URLError {
            self.init(message: urlError.code == .notConnectedToInternet
                      ? "You're offline. Check your connection and try again."
                      : "FitMix couldn't reach the server. Try again.")
            return
        }
        guard let auth = error as? AuthError else {
            self.init(message: "Something went wrong. Try again.")
            return
        }
        switch auth.errorCode {
        case .invalidCredentials:
            self.init(message: "That email and password don't match an account.")
        case .emailNotConfirmed:
            self.init(message: "Confirm your email first. Open the link we sent you, then sign in.", needsConfirmation: true)
        case .userAlreadyExists, .emailExists:
            self.init(message: "An account with this email already exists. Sign in instead.")
        case .weakPassword:
            self.init(message: auth.message.isEmpty ? "Choose a stronger password." : auth.message)
        case .samePassword:
            self.init(message: "Choose a password you haven't used for this account before.")
        case .sessionNotFound, .sessionExpired:
            self.init(message: "This reset session has ended. Request a new link and try again.")
        case .overRequestRateLimit, .overEmailSendRateLimit:
            self.init(message: "Too many attempts. Wait a few minutes and try again.")
        case .signupDisabled:
            self.init(message: "New accounts are turned off right now.")
        case .emailAddressNotAuthorized:
            self.init(message: "This email address can't receive sign-up emails yet.")
        default:
            self.init(message: auth.message.isEmpty ? "Something went wrong. Try again." : auth.message)
        }
    }
}
