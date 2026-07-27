import Foundation

/// Why a provider-side session action (`mark-issue-done`, `add-merge-label`)
/// couldn't complete.
///
/// These entry points used to be `async -> Void` that returned early on every
/// unmet precondition and swallowed every provider error, so a caller could not
/// tell "closed the issue" from "did nothing" (CROW-816). The web UI hid the
/// menu items instead; the CLI has no equivalent affordance, and hiding is not
/// a substitute for reporting in either case.
///
/// Messages name the fix where there is one — a CLI user reading
/// `add-merge-label needs a linked PR` should not have to read the source to
/// learn how to attach one.
public enum SessionActionError: Error, LocalizedError, Equatable {
    case sessionNotFound
    case managerSession(String)
    case noTicketURL(String)
    case noPRLink(String)
    case noProvider(String)
    case unsupportedByProvider(String)
    case unparseableRepo(String)
    case providerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            "Session not found"
        case .managerSession(let verb):
            "\(verb) does not apply to Manager sessions"
        case .noTicketURL(let verb):
            "\(verb) needs a linked ticket — attach one with `crow set-ticket --url …`"
        case .noPRLink(let verb):
            "\(verb) needs a linked PR — attach one with `crow add-link --type pr --url …`"
        case .noProvider(let verb):
            "\(verb) needs the session's repo to resolve to a configured provider"
        case .unsupportedByProvider(let detail):
            "Not supported by this provider: \(detail)"
        case .unparseableRepo(let url):
            "Could not parse an owner/repo slug from \(url)"
        case .providerFailed(let detail):
            "Provider call failed: \(detail)"
        }
    }
}
