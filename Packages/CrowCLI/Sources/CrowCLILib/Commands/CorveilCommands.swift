import ArgumentParser
import CrowCore
import CrowIPC
import Foundation

/// The `crow corveil` verb family.
///
/// Two groups under one command:
///
/// - **CLI binary** (CROW-1011): Settings → Corveil CLI's **Verify** and
///   **Reinstall skill** buttons, as verbs. Both act on
///   `defaults.binaries["corveil"]` — the path Settings stores — unless `--path`
///   names another, which is how you check a binary before committing it.
/// - **Connection** (CROW-1120): `connect` / `status` / `disconnect` / `orgs`
///   manage the local-only Corveil OAuth connection — the "door" the browser
///   Connect flow (corveil/crow#1119) and org provisioning (corveil/crow#1121)
///   persist a `CorveilConnection` through.
///
/// The RPCs behind every one of these are local-only on `/rpc`
/// (``RPCWebSocketHandler.localOnlyDenial``): the binary verbs execute a path on
/// the daemon host, and the connection verbs read and write OAuth tokens. That is
/// no obstacle here: `crow` reaches the daemon over its 0600 Unix socket, so a CLI
/// caller is local by construction (ADR 0002).
public struct Corveil: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "corveil",
        abstract: "Verify the Corveil CLI binary and manage the Corveil connection",
        subcommands: [
            CorveilVerify.self,
            CorveilReinstallSkill.self,
            CorveilConnect.self,
            CorveilStatus.self,
            CorveilDisconnect.self,
            CorveilOrgs.self,
            CorveilListOrgs.self,
            CorveilSelectOrg.self,
            CorveilDeselectOrg.self,
            CorveilDetectGateways.self,
            CorveilLinkGateway.self,
        ]
    )

    public init() {}
}

/// The `--path` override both subcommands accept.
///
/// An `@OptionGroup` rather than a duplicated property so the two verbs cannot
/// document it differently.
struct CorveilPathOption: ParsableArguments {
    @Option(
        name: .long,
        help: "Binary to act on. Defaults to the path in Settings → General → Corveil CLI.")
    var path: String?

    init() {}

    /// `{"path": …}` when one was given, else empty — the daemon falls back to
    /// config, so an omitted flag must not be sent as `""`.
    var params: [String: JSONValue] {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? [:] : ["path": .string(trimmed)]
    }
}

public struct CorveilVerify: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Run `corveil --version` and report what came back",
        discussion: """
        Prints `{"ok": true|false, "message": "…", "path": "…"}`. Branch on `ok`, \
        not on the exit code — a corveil that is missing, not executable, exits \
        non-zero, or hangs past 5s is a successful *report* of a broken binary.
        """
    )

    @OptionGroup var pathOption: CorveilPathOption

    public init() {}

    public func run() throws {
        printJSON(try rpc("corveil-verify", params: pathOption.params))
    }
}

public struct CorveilReinstallSkill: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reinstall-skill",
        abstract: "Reinstall every embedded slash command from the corveil binary",
        discussion: """
        Re-runs the `corveil skill install` that `crowd` runs at launch, writing \
        every embedded skill the binary ships (`corveil skill list`) into \
        `{devRoot}/.claude/commands/` — one `<skill>.md` per skill. Use it after \
        rebuilding corveil locally to pick up its new embedded skills without \
        restarting the daemon. `skill_path` in the response is that directory.

        A run also updates the launch-time corveil warning: succeeding clears \
        it, a per-skill failure replaces it, so there is one answer to "is \
        corveil broken?" rather than a startup one and a button one.
        """
    )

    @OptionGroup var pathOption: CorveilPathOption

    public init() {}

    public func run() throws {
        printJSON(try rpc("corveil-reinstall-skill", params: pathOption.params))
    }
}

// MARK: - Connection (CROW-1120)

/// `crow corveil connect` — store or update the Corveil OAuth connection.
///
/// The local-only write path: it persists the identity + tokens the browser
/// Connect flow (corveil/crow#1119) produces. Every field is optional and a blank
/// or omitted one keeps whatever is stored, so a plain access-token refresh need
/// not restate the refresh token — the same "blank keeps the stored secret"
/// contract `crow gateway set` has. The merged connection must end up with at
/// least a client id and an access token.
public struct CorveilConnect: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Store or update the Corveil connection (local-only)",
        discussion: """
        Writes the OAuth connection Crow uses to reach Corveil — the door the \
        browser Connect flow persists through. Every field is optional; a blank or \
        omitted one keeps whatever is already stored, so a token refresh can update \
        just the access token and its expiry:

          crow corveil connect --access-token "$AT" --access-token-expires-at 2026-01-01T00:00:00Z

        The merged connection must have at least a client id and an access token. \
        Tokens passed on the command line are visible to local `ps` and shell \
        history; the browser Connect flow is the primary writer. Local-only: this \
        runs over the Unix socket and is refused for remote web clients, because \
        the tokens are credentials.
        """
    )

    @Option(name: .customLong("base-url"), help: "Corveil API base URL")
    public var baseURL: String?

    @Option(name: .customLong("client-id"), help: "OAuth client id (from Dynamic Client Registration)")
    public var clientID: String?

    @Option(name: .customLong("user-id"), help: "Connected Corveil user id")
    public var userID: String?

    @Option(name: .customLong("user-email"), help: "Connected Corveil user email")
    public var userEmail: String?

    @Option(name: .customLong("user-name"), help: "Connected Corveil user display name")
    public var userName: String?

    @Option(name: .customLong("access-token"), help: "OAuth access token (secret)")
    public var accessToken: String?

    @Option(name: .customLong("refresh-token"), help: "OAuth refresh token (secret)")
    public var refreshToken: String?

    @Option(
        name: .customLong("registration-access-token"),
        help: "RFC 7592 registration access token (secret)")
    public var registrationAccessToken: String?

    @Option(
        name: .customLong("access-token-expires-at"),
        help: "Access-token expiry as an ISO-8601 timestamp (e.g. 2026-01-01T00:00:00Z)")
    public var accessTokenExpiresAt: String?

    public init() {}

    public func run() throws {
        printJSON(try rpc("corveil-connect", params: params))
    }

    /// The connection fields as RPC params, dropping every blank/omitted one so
    /// the daemon's merge keeps the stored value rather than clearing it — an
    /// empty string is not the same as "not provided".
    var params: [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        func put(_ key: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            params[key] = .string(trimmed)
        }
        put("base_url", baseURL)
        put("client_id", clientID)
        put("user_id", userID)
        put("user_email", userEmail)
        put("user_name", userName)
        put("access_token", accessToken)
        put("refresh_token", refreshToken)
        put("registration_access_token", registrationAccessToken)
        put("access_token_expires_at", accessTokenExpiresAt)
        return params
    }
}

/// `crow corveil status` — report the connection state without any secret.
public struct CorveilStatus: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the Corveil connection state (local-only)",
        discussion: """
        Reports whether a connection exists and its non-secret fields — base URL, \
        client id, connected user, org count, access-token expiry, and presence \
        booleans for the tokens. It never prints a token value.
        """
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("corveil-status"))
    }
}

/// `crow corveil disconnect` — clear the stored connection.
public struct CorveilDisconnect: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "disconnect",
        abstract: "Clear the Corveil connection (local-only)",
        discussion: """
        Removes the stored connection block, so gateway resolution and the log \
        collector stop using it. Revoking the per-org gateway keys on the Corveil \
        side is a separate step (corveil/crow#1121); this clears the local record.
        """
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("corveil-disconnect"))
    }
}

/// `crow corveil orgs` — list the connection's per-org gateway-key metadata.
public struct CorveilOrgs: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "orgs",
        abstract: "List the connection's per-org gateway keys (local-only)",
        discussion: """
        Prints the metadata for each auto-provisioned per-org gateway key — org id \
        and name, key id, display prefix, and mint time — never the key material \
        itself. This is the LOCAL record of what has been provisioned; use `corveil \
        list-orgs` to see every org you could select. Empty until an org is \
        provisioned with `corveil select-org` (corveil/crow#1121).
        """
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("corveil-orgs"))
    }
}

// MARK: - Org provisioning (CROW-1121)

/// `crow corveil list-orgs` — list the user's Corveil orgs from the API (cached).
public struct CorveilListOrgs: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list-orgs",
        abstract: "List the Corveil orgs you belong to (local-only)",
        discussion: """
        Fetches your Corveil memberships with the connection's OAuth token and \
        prints each org's id, name, role, active flag, and whether it already has a \
        provisioned gateway key. The result is cached briefly; pass `--refresh` to \
        force a re-fetch. This is the list you pick from — `corveil orgs` shows only \
        the orgs already provisioned locally. Local-only: it acts with a credential, \
        so it runs over the Unix socket and is refused for remote web clients.
        """
    )

    @Flag(name: .long, help: "Bypass the cache and re-fetch the org list from Corveil.")
    public var refresh: Bool = false

    public init() {}

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if refresh { params["refresh"] = .bool(true) }
        printJSON(try rpc("corveil-list-orgs", params: params))
    }
}

/// `crow corveil select-org` — provision (or reuse) the one gateway key for an org.
public struct CorveilSelectOrg: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "select-org",
        abstract: "Provision or reuse the gateway key for a Corveil org (local-only)",
        discussion: """
        Mints exactly one `sk-citadel-…` gateway key for the org, reusing the stored \
        one if the org already has a key — so every workspace bound to the org shares \
        it. The key value is stored as a secret; only its metadata (id, prefix, mint \
        time) is ever printed. Pass `--rotate` to force a fresh key (the old one is \
        revoked). The org name is taken from `--name` if given, else looked up from \
        your memberships. Local-only: it mints a credential over the Unix socket and \
        is refused for remote web clients.

          crow corveil select-org --org <org-id>
          crow corveil select-org --org <org-id> --rotate
        """
    )

    @Option(name: .customLong("org"), help: "Corveil organization id to provision a key for")
    public var org: String

    @Option(name: .customLong("name"), help: "Org display name to store (looked up if omitted)")
    public var name: String?

    @Flag(name: .long, help: "Revoke the existing key and mint a fresh one.")
    public var rotate: Bool = false

    public init() {}

    public func run() throws {
        var params: [String: JSONValue] = ["org_id": .string(org)]
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { params["org_name"] = .string(trimmedName) }
        if rotate { params["rotate"] = .bool(true) }
        printJSON(try rpc("corveil-select-org", params: params))
    }
}

/// `crow corveil deselect-org` — revoke an org's gateway key and drop the record.
public struct CorveilDeselectOrg: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "deselect-org",
        abstract: "Revoke a Corveil org's gateway key (local-only)",
        discussion: """
        Revokes the org's provisioned gateway key on the Corveil side and removes its \
        local metadata and stored secret. Idempotent — deselecting an org with no key \
        is a no-op. Local-only: it acts with a credential over the Unix socket and is \
        refused for remote web clients.
        """
    )

    @Option(name: .customLong("org"), help: "Corveil organization id whose key to revoke")
    public var org: String

    public init() {}

    public func run() throws {
        printJSON(try rpc("corveil-deselect-org", params: ["org_id": .string(org)]))
    }
}

// MARK: - Gateway migration (CROW-1126)

/// `crow corveil detect-gateways` — list manual `x-citadel-api-key` gateways and
/// classify each against the connection.
public struct CorveilDetectGateways: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "detect-gateways",
        abstract: "Detect manual x-citadel-api-key gateways to link to the connection (local-only)",
        discussion: """
        Scans the Manager and every workspace gateway for a hand-entered \
        `x-citadel-api-key` header — the legacy way to reach Corveil before the \
        first-class connection — and classifies each:

          managed   — already equals the connection's key for a provisioned org; nothing to do
          linkable  — a plaintext key on the connection's base URL; adopt it with `corveil link-gateway`
          manual    — not linkable yet (no connection, an op:// value, or a mismatched base URL); `reason` says why

        Key material is never printed — only a redacted prefix. Offer to link a \
        `linkable` row with:

          crow corveil link-gateway --workspace <name> --org <org-id>
          crow corveil link-gateway --manager --org <org-id>
        """
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("corveil-detect-gateways"))
    }
}

/// `crow corveil link-gateway` — adopt a detected gateway's existing plaintext key
/// into the connection as a named org's key.
public struct CorveilLinkGateway: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "link-gateway",
        abstract: "Adopt a manual gateway's key into the connection as an org's key (local-only)",
        discussion: """
        Records the target's existing plaintext `x-citadel-api-key` value as \
        `--org`'s key in the Corveil connection, so the connection now owns it and \
        the org shows as provisioned. Non-disruptive — the running key is unchanged \
        — and offline: the Corveil backend has no key→org lookup, so you name the \
        org. The adopted key is stored with no key id (it was minted by hand); a \
        later `corveil select-org` on that org mints a real managed key.

          crow corveil link-gateway --workspace MyOrg --org <org-id>
          crow corveil link-gateway --manager --org <org-id> --org-name "My Org"

        Only a gateway on the connection's own base URL is adopted (the key would \
        otherwise be sent to the wrong host), and op:// references are refused. If \
        the org already has a *provisioned* key, retire it with `corveil \
        deselect-org --org <org-id>` first — that revokes it on Corveil — then link. \
        Local-only: it authors a credential into the connection over the Unix \
        socket and is refused for remote web clients.
        """
    )

    @Option(name: .customLong("workspace"), help: "Workspace whose gateway to link (name or UUID)")
    public var workspace: String?

    @Flag(name: .customLong("manager"), help: "Link the Manager gateway instead of a workspace")
    public var manager: Bool = false

    @Option(name: .customLong("org"), help: "Corveil organization id to record the key under")
    public var org: String

    @Option(name: .customLong("org-name"), help: "Org display name to store (optional)")
    public var orgName: String?

    public init() {}

    /// Exactly one target must be named. `validate()` (not `run()`) so the check
    /// runs before any daemon round-trip and is unit-testable without a socket.
    public func validate() throws {
        let hasWorkspace =
            !(workspace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        guard manager != hasWorkspace else {
            throw ValidationError("Pass exactly one of --manager or --workspace <name|uuid>.")
        }
    }

    public func run() throws {
        // Same target selector as `crow gateway`: `target: "manager"` OR
        // `workspace: <name|uuid>`, resolved daemon-side via SecretsRPC.decodeTarget.
        var params: [String: JSONValue] = ["org_id": .string(org)]
        if manager {
            params["target"] = .string("manager")
        } else {
            let workspaceRef = workspace?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            params["workspace"] = .string(workspaceRef)
        }
        let trimmedName = orgName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { params["org_name"] = .string(trimmedName) }
        printJSON(try rpc("corveil-link-gateway", params: params))
    }
}
