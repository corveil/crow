import Foundation

/// Detects manual `x-citadel-api-key` AI gateways and links (adopts) them into the
/// first-class ``CorveilConnection`` (CROW-1126) — the migration half of the
/// first-class-Corveil epic (corveil/crow#1117).
///
/// Before the connection existed, a Corveil gateway was configured by hand: a
/// base URL plus an `x-citadel-api-key` header holding a `sk-citadel-…` key
/// (``WorkspaceGateway``). The epic replaced that with a connection whose
/// per-org key *generates* the same gateway (``CorveilConnection/derivedGateway(orgID:)``).
/// This type is the bridge for installs that predate the connection:
///
///   - ``detect(config:)`` enumerates every gateway (Manager + each workspace)
///     that carries the `x-citadel-api-key` header and classifies it as already
///     **managed** by the connection, **linkable** (adoptable), or **manual**
///     (why it can't be linked yet).
///   - ``link(config:target:orgID:orgName:force:now:)`` **adopts** a linkable
///     gateway's existing plaintext key into the connection as the named org's
///     key — a non-disruptive record write (the running key is unchanged), so the
///     connection now "owns" the org and the org dropdown reflects it.
///
/// Adoption is deliberately offline and does **not** re-mint: the Corveil backend
/// has no key→org lookup (``CorveilAPIClient`` only lists/mints/revokes), so the
/// org is always user-supplied — the acceptance criterion's "where possible". The
/// adopted key is recorded with an **empty `keyID`** (it was minted by hand, not by
/// this client), which is also the upgrade path: a later `corveil select-org` sees
/// the empty id, skips the reuse fast-path (``CorveilOrgProvisioner/provision``
/// requires a non-empty id), and mints a real managed key.
public enum CorveilGatewayMigration {

    /// Which gateway a candidate/link refers to — the Manager's own gateway, or a
    /// named workspace's.
    public enum Target: Sendable, Equatable {
        case manager
        case workspace(String)

        /// Wire tag for the RPC/CLI payload.
        public var kind: String {
            switch self {
            case .manager: return "manager"
            case .workspace: return "workspace"
            }
        }
    }

    /// Whether a detected header value is a plaintext secret or a `op://` 1Password
    /// reference. Only plaintext values can be adopted — the connection stores raw
    /// `sk-citadel-…` values, not references.
    public enum ValueKind: String, Sendable, Equatable {
        case plaintext
        case opReference
    }

    /// The state of one detected `x-citadel-api-key` gateway relative to the stored
    /// connection.
    public enum Classification: Sendable, Equatable {
        /// Already equals the connection's derived gateway for a provisioned org —
        /// nothing to migrate.
        case managed(orgID: String, orgName: String)
        /// A stored connection exists, the value is plaintext, and the base URL
        /// matches the connection's — ready to adopt with ``link``.
        case linkable
        /// Not adoptable yet; `reason` says why (no connection / `op://` value /
        /// base-URL mismatch) so the CLI can print an actionable hint.
        case manual(reason: String)

        /// Wire tag for the RPC/CLI payload.
        public var kind: String {
            switch self {
            case .managed: return "managed"
            case .linkable: return "linkable"
            case .manual: return "manual"
            }
        }
    }

    /// One detected `x-citadel-api-key` gateway.
    public struct Candidate: Sendable, Equatable {
        public let target: Target
        /// Human label for the target — `"Manager"` or the workspace name.
        public let targetName: String
        public let baseURL: String
        public let valueKind: ValueKind
        /// A redacted display hint for the key — never the full secret.
        public let keyPrefix: String
        public let classification: Classification

        public init(
            target: Target, targetName: String, baseURL: String,
            valueKind: ValueKind, keyPrefix: String, classification: Classification
        ) {
            self.target = target
            self.targetName = targetName
            self.baseURL = baseURL
            self.valueKind = valueKind
            self.keyPrefix = keyPrefix
            self.classification = classification
        }
    }

    /// Everything that can stop a ``link``.
    public enum LinkError: Error, CustomStringConvertible, Equatable {
        case notConnected
        case unknownTarget(String)
        case noCitadelGateway
        case notPlaintext
        case orgRequired
        case baseURLMismatch(gateway: String, connection: String)
        case orgAlreadyProvisioned(orgID: String)

        public var description: String {
            switch self {
            case .notConnected:
                return "no Corveil connection — run `crow corveil connect` first"
            case .unknownTarget(let name):
                return "no workspace named \(name)"
            case .noCitadelGateway:
                return "that target has no manual x-citadel-api-key gateway to link"
            case .notPlaintext:
                return "the gateway key is an op:// reference — link adopts plaintext keys only"
            case .orgRequired:
                return "an organization id is required"
            case .baseURLMismatch(let gateway, let connection):
                return "the gateway base URL \(gateway) doesn't match the Corveil connection "
                    + "(\(connection)) — this key isn't for that host"
            case .orgAlreadyProvisioned(let orgID):
                return "organization \(orgID) already has a provisioned key — run "
                    + "`crow corveil deselect-org --org \(orgID)` to revoke it first, then link"
            }
        }
    }

    // MARK: - Detect

    /// Every gateway carrying an `x-citadel-api-key` header, classified against the
    /// stored connection. The Manager gateway is listed first, then workspaces in
    /// config order. Gateways without the header (a non-Corveil proxy) are ignored.
    public static func detect(config: AppConfig) -> [Candidate] {
        let connection = usableConnection(config)
        var candidates: [Candidate] = []

        if let gateway = config.managerGateway, let value = citadelValue(gateway) {
            candidates.append(
                classify(target: .manager, targetName: "Manager", gateway: gateway,
                         value: value, connection: connection))
        }
        for workspace in config.workspaces {
            guard let gateway = workspace.gateway, let value = citadelValue(gateway) else { continue }
            candidates.append(
                classify(target: .workspace(workspace.name), targetName: workspace.name,
                         gateway: gateway, value: value, connection: connection))
        }
        return candidates
    }

    private static func classify(
        target: Target, targetName: String, gateway: WorkspaceGateway,
        value: String, connection: CorveilConnection?
    ) -> Candidate {
        let base = gateway.baseURL.trimmingCharacters(in: .whitespaces)
        let kind: ValueKind = isOpReference(value) ? .opReference : .plaintext
        let classification = classifyValue(base: base, value: value, kind: kind, connection: connection)
        return Candidate(
            target: target, targetName: targetName, baseURL: base,
            valueKind: kind, keyPrefix: redactedPrefix(value, kind: kind),
            classification: classification)
    }

    private static func classifyValue(
        base: String, value: String, kind: ValueKind, connection: CorveilConnection?
    ) -> Classification {
        guard let connection else {
            return .manual(reason: "no Corveil connection — run `crow corveil connect` first")
        }
        // Managed: this gateway already equals the connection's derived gateway for
        // some provisioned org (same base URL and same stored key secret).
        let connBase = connection.baseURL.trimmingCharacters(in: .whitespaces)
        if sameBaseURL(base, connBase) {
            let trimmedValue = value.trimmingCharacters(in: .whitespaces)
            if let match = connection.orgKeys.first(where: { key in
                guard let secret = connection.orgKeySecrets[key.orgID] else { return false }
                return secret.trimmingCharacters(in: .whitespaces) == trimmedValue && !trimmedValue.isEmpty
            }) {
                return .managed(orgID: match.orgID, orgName: match.orgName)
            }
        }
        if kind == .opReference {
            return .manual(reason: "op:// reference — link adopts plaintext keys only")
        }
        guard sameBaseURL(base, connBase) else {
            return .manual(
                reason: "base URL \(base) doesn't match the connection (\(connBase))")
        }
        return .linkable
    }

    // MARK: - Link (adopt)

    /// Adopt the target's existing plaintext `x-citadel-api-key` value into the
    /// connection as `orgID`'s key. Mutates `config` in place and returns the
    /// recorded ``CorveilOrgKey``. Pure config write — no network.
    ///
    /// The key is stored verbatim (so ``CorveilConnection/derivedGateway(orgID:)``
    /// reproduces the original gateway exactly) with an empty `keyID` marking it as
    /// adopted rather than minted. Enforces the same preconditions ``detect``
    /// classifies as `.linkable`: refuses an `op://` value, a missing header, a
    /// blank org, and a **base URL that doesn't match the connection** — because
    /// `derivedGateway` pairs the adopted secret with the *connection's* base URL,
    /// so a foreign-host key would be sent to the wrong gateway.
    ///
    /// Also refuses to overwrite an org that already has a **minted** key (non-empty
    /// `keyID`): replacing it here would drop the only handle `deselect-org` revokes
    /// by, orphaning a live key on Corveil. Retire it with `deselect-org` first
    /// (which revokes server-side), then link.
    @discardableResult
    public static func link(
        config: inout AppConfig,
        target: Target,
        orgID: String,
        orgName: String?,
        now: Date = Date()
    ) throws -> CorveilOrgKey {
        guard var connection = config.corveilConnection, !connection.isEmpty else {
            throw LinkError.notConnected
        }
        let trimmedOrg = orgID.trimmingCharacters(in: .whitespaces)
        guard !trimmedOrg.isEmpty else { throw LinkError.orgRequired }

        let gateway: WorkspaceGateway?
        switch target {
        case .manager:
            gateway = config.managerGateway
        case .workspace(let name):
            guard let workspace = config.workspaces.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else { throw LinkError.unknownTarget(name) }
            gateway = workspace.gateway
        }
        guard let gateway, let value = citadelValue(gateway) else { throw LinkError.noCitadelGateway }
        guard !isOpReference(value) else { throw LinkError.notPlaintext }
        // The key must belong to the connection's host — `detect` classifies a
        // base-URL mismatch as `.manual` (not linkable) for exactly this reason.
        guard sameBaseURL(gateway.baseURL, connection.baseURL) else {
            throw LinkError.baseURLMismatch(
                gateway: gateway.baseURL.trimmingCharacters(in: .whitespaces),
                connection: connection.baseURL.trimmingCharacters(in: .whitespaces))
        }

        // Refuse to clobber a MINTED key: its `keyID` is the handle `deselect-org`
        // revokes by, and overwriting it with an adopted (empty-`keyID`) row would
        // strand a live key on Corveil. An adopted key has no server-side handle,
        // so re-adopting one is fine.
        let existing = connection.orgKeys.first { $0.orgID == trimmedOrg }
        if let existing, !existing.keyID.isEmpty {
            throw LinkError.orgAlreadyProvisioned(orgID: trimmedOrg)
        }

        let resolvedName: String = {
            let given = orgName?.trimmingCharacters(in: .whitespaces) ?? ""
            if !given.isEmpty { return given }
            return existing?.orgName ?? ""
        }()

        let orgKey = CorveilOrgKey(
            orgID: trimmedOrg,
            orgName: resolvedName,
            keyID: "",  // adopted by hand, not minted by this client
            keyPrefix: redactedPrefix(value, kind: .plaintext),
            createdAt: now)
        connection.orgKeys.removeAll { $0.orgID == trimmedOrg }
        connection.orgKeys.append(orgKey)
        connection.orgKeySecrets[trimmedOrg] = value
        config.corveilConnection = connection
        return orgKey
    }

    // MARK: - Helpers

    /// The stored connection, or nil when there is none / it's an empty shell.
    private static func usableConnection(_ config: AppConfig) -> CorveilConnection? {
        guard let connection = config.corveilConnection, !connection.isEmpty else { return nil }
        return connection
    }

    /// The non-blank `x-citadel-api-key` header value (matched case-insensitively),
    /// returned **verbatim** (not trimmed) so an adopted value reproduces the
    /// original gateway exactly. Nil when the header is absent or blank.
    static func citadelValue(_ gateway: WorkspaceGateway) -> String? {
        for (key, value) in gateway.customHeaders
        where key.caseInsensitiveCompare(CorveilConnection.gatewayAPIKeyHeader) == .orderedSame {
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
        }
        return nil
    }

    private static func isOpReference(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("op://")
    }

    /// Normalize a base URL for comparison the way the rest of the Corveil stack
    /// does (`CorveilAPIClient.Endpoints` / `CorveilOAuthClient.Endpoints`): trim
    /// whitespace and drop a single trailing slash, so `…/example` and `…/example/`
    /// — the same host typed two ways — compare equal.
    static func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private static func sameBaseURL(_ a: String, _ b: String) -> Bool {
        normalizedBaseURL(a) == normalizedBaseURL(b)
    }

    /// A short, non-secret display hint for a key value — a leading `Bearer ` is
    /// stripped, then a prefix is shown with an ellipsis if the value is longer.
    /// An `op://` reference is not a secret, so it's shown as-is. Mirrors the
    /// backend's own `key_prefix` (a prefix of the key, not the whole thing).
    static func redactedPrefix(_ value: String, kind: ValueKind) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if kind == .opReference { return trimmed }
        var core = trimmed
        if core.lowercased().hasPrefix("bearer ") { core = String(core.dropFirst(7)) }
        core = core.trimmingCharacters(in: .whitespaces)
        let limit = 14
        if core.count <= limit { return core }
        return String(core.prefix(limit)) + "…"
    }
}
