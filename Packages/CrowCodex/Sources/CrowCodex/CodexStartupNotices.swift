import Foundation

/// Codex's full-screen startup prompts, and how Crow keeps them from stalling
/// an unattended launch (CROW-1410).
///
/// Codex can stop before its first turn on a screen that needs a keypress.
/// Three of them matter to Crow, and they need different fixes. The first two
/// come from the `rust-v0.166.0` source of openai/codex
/// (`codex-rs/tui/src/{lib.rs,updates.rs,app/startup_prompts.rs,model_migration.rs}`)
/// and were reproduced against codex-cli 0.166.0 in a scratch `CODEX_HOME`.
/// The third arrived in 0.167.0 (CROW-1425).
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
/// 3. **Read-only provider notice** (0.167.0+, openai/codex#58202,
///    `codex-rs/tui/src/chatwidget/provider_error.rs`). Since 0.167.0,
///    `resume --last` and by-id resume find a thread recorded under any
///    `model_provider`. When the current provider can't continue it, Codex
///    opens the thread as read-only history with the composer disabled and a
///    `🔒` notice whose footer is `c continue in new chat · n start fresh · esc
///    other chats`. Crow hits it whenever a resume's provider differs from the
///    thread's: toggling `--codex-upstream` routing on gives *"Continue in a
///    new chat"* (provider mismatch), and toggling it off gives *"Model
///    provider unavailable"*, because the per-run `crow-corveil` provider is no
///    longer configured. Typed text never reaches a composer there: letters
///    other than `c`/`n` are dropped, so a `crow send` either vanishes or
///    triggers a shortcut. Codex 0.166 skipped such threads and opened a fresh
///    TUI instead. The daemon answers `n` (start fresh), which restores that
///    outcome. `c` is not used: it fills the new composer with a draft built
///    from the old transcript, and a later `crow send` would be appended to it.
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

    /// The startup screens Crow answers.
    public enum Screen: String, Equatable, Sendable {
        /// "Meet <model> … 1. Try new model / 2. Use existing model".
        case modelMigration = "model-migration prompt"
        /// The 0.167+ read-only notice on a resumed thread whose provider the
        /// launch can't use.
        case providerNotice = "read-only model-provider notice"

        /// Whether Codex can draw another startup screen after this one. The
        /// migration prompt runs before the thread is resumed, so the provider
        /// notice can still follow it. Nothing follows the provider notice.
        public var isLastStartupScreen: Bool { self == .providerNotice }
    }

    /// What to do about the screen a Codex pane is showing.
    public enum Response: Equatable, Sendable {
        /// A screen Crow answers. Send these tmux keys, one `send-keys` call
        /// each.
        ///
        /// - ``Screen/modelMigration``: ``useExistingModelKeys``. Pressing `2`
        ///   first matters: Enter and Esc both *confirm the highlighted option*,
        ///   and "Try new model" is highlighted when the screen opens.
        /// - ``Screen/providerNotice``: ``startFreshKeys``.
        case answer(keys: [String], screen: Screen)
        /// The model-migration prompt with no opt-out: the current model is no
        /// longer in the catalog, so the only choice switches models. Crow
        /// doesn't make that choice. The session waits for the operator.
        case needsOperator(reason: String)
    }

    /// The keys that pick "Use existing model" on the migration screen.
    public static let useExistingModelKeys = ["2", "Enter"]

    /// The key that picks "start fresh" on the read-only provider notice. A
    /// plain `n`, with no Enter: the notice acts on the bare keypress.
    public static let startFreshKeys = ["n"]

    /// The provider notice's titles (`ProviderErrorNotice.title` in 0.167.1):
    /// provider mismatch, provider no longer configured, and the two policy
    /// conflicts, which share a title.
    static let providerNoticeTitles = [
        "Continue in a new chat",
        "Model provider unavailable",
        "Model provider blocked by policy",
    ]

    /// How many rows up from the footer the notice's title may sit. The
    /// description between them is one row in a wide pane and grows as the
    /// pane narrows (four rows at 50 columns for "Model provider unavailable").
    static let providerNoticeMaxDescriptionRows = 10

    /// How Crow should respond to `screen`, a capture of the pane's visible
    /// rows (`capture-pane -p`, no escapes), or nil when it shows no prompt
    /// Crow handles.
    ///
    /// Only the bottom of the screen counts. Each prompt is the last thing
    /// Codex draws, so its key hint is the last non-blank row (or rows, when a
    /// narrow pane wraps the provider notice's hint). The migration prompt's two
    /// options sit directly above it, and the provider notice's `🔒` title a
    /// few rows above. In a running session the bottom rows are always the
    /// composer and status line, so a transcript that merely quotes a prompt,
    /// such as a ticket about it, never matches.
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
            return .answer(keys: useExistingModelKeys, screen: .modelMigration)
        }
        if matches(footer, migrationFooter(verb: "continue")) {
            return .needsOperator(
                reason: "Codex is waiting on a startup prompt with no keep-current option (a required model switch)")
        }
        if isProviderNotice(rows) {
            return .answer(keys: startFreshKeys, screen: .providerNotice)
        }
        return nil
    }

    /// The provider notice: its key-hint footer (up to three wrapped rows,
    /// re-joined with single spaces) at the bottom, and one of
    /// ``providerNoticeTitles`` behind the `🔒` within
    /// ``providerNoticeMaxDescriptionRows`` rows above it. The `c continue in new
    /// chat · ` lead is absent when Codex can't offer a continuation (the policy
    /// variants), so it is optional. `n start fresh` is in every variant.
    private static func isProviderNotice(_ rows: [String]) -> Bool {
        guard !rows.isEmpty else { return false }
        for footerRows in 1...min(3, rows.count) {
            let footer = rows.suffix(footerRows).joined(separator: " ")
            guard matches(footer, providerNoticeFooter) else { continue }
            let above = rows.dropLast(footerRows).suffix(providerNoticeMaxDescriptionRows + 1)
            return above.contains { providerNoticeTitles.contains(lockedTitle($0) ?? "") }
        }
        return false
    }

    /// `🔒  Title` → `Title`, or nil when the row doesn't start with the lock.
    /// Codex 0.167.1 draws a bare U+1F512; a trailing variation selector is
    /// tolerated in case a terminal or font substitutes the emoji form.
    private static func lockedTitle(_ row: String) -> String? {
        let scalars = row.unicodeScalars
        guard scalars.first == "\u{1F512}" else { return nil }
        let rest = scalars.dropFirst().drop { $0 == "\u{FE0F}" }
        return String(String.UnicodeScalarView(rest)).trimmingCharacters(in: .whitespaces)
    }

    /// `c continue in new chat · n start fresh · esc other chats`, or the same
    /// without its first shortcut.
    private static let providerNoticeFooter =
        "^(c continue in new chat · )?n start fresh · esc other chats$"

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
