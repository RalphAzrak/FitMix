import Foundation
import Supabase

/// Supabase project settings. The publishable key is meant to ship in client apps;
/// access to data is controlled by the project's row-level security, not by this key.
enum SupabaseConfig {
    static let url = URL(string: "https://hdxpakrlayubyhagbrrw.supabase.co")!
    static let publishableKey = "sb_publishable_brDJuQaIYtYr9rxy-e8R7w_fqdC63Cv"
}

/// The signed-in FitMix account, as shown in the app.
struct AccountUser: Equatable {
    var id: UUID
    var email: String?
    var fullName: String?

    init(_ user: User) {
        id = user.id
        email = user.email
        fullName = user.userMetadata["full_name"]?.stringValue
    }
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

    private(set) var state: State = .restoring

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
