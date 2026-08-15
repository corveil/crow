import ArgumentParser
import CrowCore
import CrowIPC
import Foundation

/// The `crow corveil` verb family (CROW-1011).
///
/// Settings → Corveil CLI's **Verify** and **Reinstall skill** buttons, as CLI
/// verbs. Both act on `defaults.binaries["corveil"]` — the path Settings stores
/// — unless `--path` names another, which is how you check a binary before
/// committing it to config.
///
/// The RPCs behind these are local-only on `/rpc`
/// (``RPCWebSocketHandler.localOnlyDenial``) because they execute a path on the
/// daemon host. That is no obstacle here: `crow` reaches the daemon over its
/// 0600 Unix socket, so a CLI caller is local by construction (ADR 0002).
public struct Corveil: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "corveil",
        abstract: "Verify the configured Corveil CLI binary, and reinstall its skill",
        subcommands: [CorveilVerify.self, CorveilReinstallSkill.self]
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
