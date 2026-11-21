import Foundation
import os
import Supabase

/// DEBUG-only trace of the email-link auth flow (sign-up, resend, callbacks, PKCE exchange).
///
/// Shows in Xcode's console and Console.app under subsystem `app.fitmix`, category `AuthFlow`,
/// every line prefixed with `[AuthFlow]`. Release builds compile every call to nothing.
///
/// Only fixed labels and sanitized values are logged: URL scheme and host, HTTP status, and
/// Supabase's own error code. Never the full URL, query, fragment, auth code, verifier, tokens,
/// email, or password.
enum AuthDebugLog {
    #if DEBUG
    private static let logger = Logger(subsystem: "app.fitmix", category: "AuthFlow")
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.debug("[AuthFlow] \(text, privacy: .public)")
        #endif
    }

    /// `scheme://host` only, e.g. `fitmix://confirm-email` or `https://<ref>.supabase.co`.
    static func origin(_ url: URL) -> String {
        "\(clean(url.scheme ?? "none"))://\(clean(url.host ?? ""))"
    }

    /// A short label for an auth failure: Supabase's error code and the HTTP status when the
    /// server answered, the URL error code when it didn't. Never the server's message text.
    static func category(_ error: Error) -> String {
        if let urlError = error as? URLError { return "network urlError=\(urlError.code.rawValue)" }
        guard let auth = error as? AuthError else { return "other type=\(clean(String(describing: type(of: error))))" }
        switch auth {
        case .api(_, let code, _, let response):
            return "api error_code=\(clean(code.rawValue)) http=\(response.statusCode)"
        case .pkceGrantCodeExchange(let message, let error, let code):
            if error != nil || code != nil {
                return "pkce callback_error=\(clean(error ?? "-")) error_code=\(clean(code ?? "-"))"
            }
            if message.contains("code verifier") { return "pkce verifier_missing (link opened on another device or install, or already used)" }
            if message.contains("No code") { return "pkce no_code" }
            return "pkce not_a_pkce_url"
        case .weakPassword:
            return "weak_password"
        case .sessionMissing:
            return "session_missing"
        default:
            return "auth error_code=\(clean(auth.errorCode.rawValue))"
        }
    }

    /// Keeps only characters that appear in schemes, hosts, and Supabase error codes, so values
    /// from an incoming URL can't smuggle anything else into the log.
    static func clean(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return String(value.filter { allowed.contains($0) }.prefix(64))
    }
}
