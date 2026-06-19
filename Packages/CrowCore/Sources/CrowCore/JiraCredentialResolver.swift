import Foundation

/// Resolves a ``JiraCredential`` into the HTTP Basic `Authorization` header used
/// by the in-app Jira REST status fetch (CROW-528).
///
/// The token (`tokenRef`) may be a plaintext string or an `op://…` 1Password
/// reference; references are resolved via the `op` CLI so the secret never lands
/// at rest in `config.json`. The output is an HTTP Basic credential —
/// `Basic base64("\(username):\(token)")` — matching Jira's personal-API-token
/// auth.
///
/// Resolved secret values are never logged.
public enum JiraCredentialResolver {
    /// Resolve a credential's token (resolving an `op://…` reference) and build
    /// the Basic-auth `Authorization` header value. Returns `nil` for an empty
    /// credential, or when the username/token is missing or the secret reference
    /// fails to resolve.
    ///
    /// - Parameter resolveSecret: Injected for testability; defaults to `op read`.
    public static func resolve(
        _ credential: JiraCredential,
        resolveSecret: (String) -> String? = GatewayResolver.opRead
    ) -> String? {
        guard !credential.isEmpty else { return nil }

        let username = credential.username.trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty else {
            NSLog("[JiraCredentialResolver] No username set; cannot build Jira auth header")
            return nil
        }

        let tokenRef = credential.tokenRef.trimmingCharacters(in: .whitespaces)
        guard !tokenRef.isEmpty else {
            NSLog("[JiraCredentialResolver] No API token set; cannot build Jira auth header")
            return nil
        }

        let token: String
        if tokenRef.hasPrefix("op://") {
            guard let secret = resolveSecret(tokenRef) else {
                NSLog("[JiraCredentialResolver] Failed to resolve API token reference (op read failed or op not signed in)")
                return nil
            }
            token = secret
        } else {
            token = tokenRef
        }

        let credentialString = "\(username):\(token)"
        guard let encoded = credentialString.data(using: .utf8)?.base64EncodedString() else {
            return nil
        }
        return "Basic \(encoded)"
    }
}
