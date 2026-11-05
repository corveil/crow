import Foundation

/// Codex's full-screen startup prompts, and how Crow keeps them from stalling
/// an unattended launch (CROW-1410).
///
/// Codex can stop before its first turn on a screen that needs a keypress.
/// Two of them matter to Crow, and they need different fixes. Both findings
/// come from the `rust-v0.166.0` source of openai/codex
/// (`codex-rs/tui/src/{lib.rs,updates.rs,app/startup_prompts.rs,model_migration.rs}`)
/// and were reproduced against codex-cli 0.166.0 in a scratch `CODEX_HOME`.
///
/// 1. **Update available.** `run_update_prompt_if_needed` runs when the cached
///    `version.json` names a newer release. Its highlighted default is
///    "Update now", which runs `npm install -g @openai/codex`. It is skipped
///    when a prompt is passed on argv, so it blocks the launches that carry
///    none: Managers, and every `resume`. `check_for_update_on_startup=false`
///    turns it off, per run, without touching `~/.codex/config.toml`. That is
///    ``configOverrides``.
///
/// 2. **Model migration** ("Meet GPT-6 Sol … 1. Try new model / 2. Use
///    existing model"). It runs on every launch, prompt or not, when the
///    server's model catalog gives the current model an `upgrade`. Codex
///    suppresses it only when `notice.model_migrations[<current>] == <target>`
///    (or through two legacy `hide_gpt5_1…` flags that match only those
///    retired slugs). Both slugs come from the catalog Codex fetches at
///    startup, so Crow can't write that override ahead of time. Instead, the
///    daemon reads the pane and answers the screen with "Use existing model",
///    the choice that changes nothing. ``response(toScreen:)`` decides that from
///    the pane text. Codex then records the acknowledgment itself, exactly as
///    if the operator had pressed it.
///
/// Every value here is free of `"`, because prompt-seeded launches sit inside
/// `eval "…"` (`ShellLaunchArgs.evalPromptLaunch`).
public enum CodexStartupNotices {
    /// The per-run `-c` override that disables the startup update prompt, with
    /// a leading space so it appends directly after the `codex` binary.
    /// Root-level `-c` also applies to `codex resume …`, so one placement
    /// covers fresh launches and resumes.
    ///
    /// This also stops Codex's background release check, so a Crow-launched
    /// Codex no longer mentions new versions. Crow already reports versions on
    /// its own surfaces, and an update has to be installed outside the pane
    /// anyway.
    public static let configOverrides = " -c check_for_update_on_startup=false"

    /// Whether `command` is a Crow-built Codex launch: every one carries
    /// ``configOverrides``. Keys the startup-prompt watch, the same way
    /// `CodexGatewayArgs.commandRequestsKey` keys the gateway key export.
    public static func isCodexLaunch(_ command: String) -> Bool {
        command.contains(configOverrides)
    }

    /// What to do about the screen a Codex pane is showing.
    public enum Response: Equatable, Sendable {
        /// The model-migration prompt with its opt-out. Send these tmux keys,
        /// one `send-keys` call each, to pick "Use existing model". Pressing
        /// `2` first matters: Enter and Esc both *confirm the highlighted
        /// option*, and "Try new model" is highlighted when the screen opens.
        case answer(keys: [String])
        /// The model-migration prompt with no opt-out: the current model is no
        /// longer in the catalog, so the only choice switches models. Crow
        /// doesn't make that choice. The session waits for the operator.
        case needsOperator(reason: String)
    }

    /// The keys that pick "Use existing model" on the migration screen.
    public static let useExistingModelKeys = ["2", "Enter"]

    /// How Crow should respond to `screen`, a capture of the pane's visible
    /// rows (`capture-pane -p`, no escapes), or nil when it shows no prompt
    /// Crow handles.
    ///
    /// Only the bottom of the screen counts. The migration prompt is the last
    /// thing Codex draws, so its key hint is the last non-blank row and its
    /// two options sit directly above it. In a running session the bottom rows
    /// are always the composer and status line, so a transcript that merely
    /// quotes the prompt, such as a ticket about it, never matches.
    public static func response(toScreen screen: String) -> Response? {
        let rows = screen
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let footer = rows.last else { return nil }

        if matches(footer, migrationFooter(verb: "confirm")) {
            guard rows.count >= 3,
                  matches(rows[rows.count - 3], option(1, "Try new model")),
                  matches(rows[rows.count - 2], option(2, "Use existing model"))
            else { return nil }
            return .answer(keys: useExistingModelKeys)
        }
        if matches(footer, migrationFooter(verb: "continue")) {
            return .needsOperator(
                reason: "Codex is waiting on a startup prompt with no keep-current option (a required model switch)")
        }
        return nil
    }

    /// `enter/esc confirm · ⌃c quit`. The Ctrl label is platform-dependent
    /// (`⌃c` on macOS, `ctrl + c` elsewhere), so any label is accepted.
    private static func migrationFooter(verb: String) -> String {
        "^enter/esc \(verb) · .{1,12} quit$"
    }

    /// `› 1. Try new model` (highlighted) or `1. Try new model`.
    private static func option(_ number: Int, _ label: String) -> String {
        "^(› )?\(number)\\. \(label)$"
    }

    private static func matches(_ row: String, _ pattern: String) -> Bool {
        row.range(of: pattern, options: .regularExpression) != nil
    }
}
