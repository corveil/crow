import Foundation

/// A detected change in a session's `PRStatus` that warrants user attention.
///
/// `.changesRequested` is emitted by the stateless `PRStatus.needsRefine`
/// path in `IssueTracker` (CROW-508). `.checksFailing` is still edge-detected
/// from the previous PR status — checks that just flipped from passing/pending
/// to failing on a new commit.
public struct PRStatusTransition: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// A reviewer has CHANGES_REQUESTED and the agent hasn't responded
        /// with a substantive commit since. Emitted on every poll the rule
        /// holds, gated by the per-PR cooldown in `IssueTracker`.
        case changesRequested
        /// At least one CI/CD check newly transitioned to failing on the
        /// current head commit.
        case checksFailing
    }

    public let kind: Kind
    public let sessionID: UUID
    public let prURL: String
    public let prNumber: Int?
    /// Head commit SHA at the moment of the transition. Carried through to
    /// downstream consumers (logging, AutoRespondCoordinator) but is no
    /// longer part of any dedupe key (CROW-508 removed the meta map).
    public let headSha: String?
    /// Names of failing checks (empty for `.changesRequested`).
    public let failedCheckNames: [String]
    /// True when this `.changesRequested` is the second-or-later dispatch
    /// for the same reviewer submission (cooldown re-fire on a stuck-idle
    /// agent). The re-prompt to the agent is still useful — that's the
    /// whole point of the cooldown — but a fresh macOS notification every
    /// cooldown window for the same review id is pure noise, so
    /// `AppDelegate.onPRStatusTransitions` skips `notifyPRTransition` when
    /// this flag is set. Always `false` for `.checksFailing`.
    public let isCooldownReFire: Bool

    public init(
        kind: Kind,
        sessionID: UUID,
        prURL: String,
        prNumber: Int? = nil,
        headSha: String? = nil,
        failedCheckNames: [String] = [],
        isCooldownReFire: Bool = false
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.prURL = prURL
        self.prNumber = prNumber
        self.headSha = headSha
        self.failedCheckNames = failedCheckNames
        self.isCooldownReFire = isCooldownReFire
    }
}

extension PRStatus {
    /// Compute the `.checksFailing` transition (if any) implied by moving from
    /// `old` to `new`. `.changesRequested` is no longer computed here — the
    /// stateless `needsRefine` path in `IssueTracker` handles it directly off
    /// the PR snapshot (CROW-508).
    ///
    /// On the first observation (`old == nil`), emits a `.checksFailing`
    /// transition only when the new state itself is failing — same
    /// startup-flood safety the prior implementation provided for CI.
    ///
    /// - Note: This is the pure piece of the transition pipeline; the
    ///   stateful dedupe (across polls) lives in `IssueTracker`.
    public static func transitions(
        from old: PRStatus?,
        to new: PRStatus,
        sessionID: UUID,
        prURL: String,
        prNumber: Int?
    ) -> [PRStatusTransition] {
        var out: [PRStatusTransition] = []

        let wasFailing = old?.checksPass == .failing
        if !wasFailing, new.checksPass == .failing {
            out.append(PRStatusTransition(
                kind: .checksFailing,
                sessionID: sessionID,
                prURL: prURL,
                prNumber: prNumber,
                headSha: new.headSha,
                failedCheckNames: new.failedCheckNames
            ))
        }

        return out
    }
}
