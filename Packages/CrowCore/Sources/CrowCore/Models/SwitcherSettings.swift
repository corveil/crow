import Foundation

/// Session-switcher ordering mode (CROW-976).
public enum SwitcherOrder: String, Codable, Sendable, Equatable {
    case mru
    case sidebar
}

/// Per-category / per-status filters for the session switcher overlay.
public struct SwitcherIncludeSettings: Codable, Sendable, Equatable {
    public var managers: Bool
    public var jobs: Bool
    public var reviews: Bool
    public var active: Bool
    public var paused: Bool
    public var inReview: Bool
    public var completed: Bool
    public var archived: Bool

    public init(
        managers: Bool = false,
        jobs: Bool = false,
        reviews: Bool = true,
        active: Bool = true,
        paused: Bool = true,
        inReview: Bool = true,
        completed: Bool = false,
        archived: Bool = false
    ) {
        self.managers = managers
        self.jobs = jobs
        self.reviews = reviews
        self.active = active
        self.paused = paused
        self.inReview = inReview
        self.completed = completed
        self.archived = archived
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        managers = try c.decodeIfPresent(Bool.self, forKey: .managers) ?? false
        jobs = try c.decodeIfPresent(Bool.self, forKey: .jobs) ?? false
        reviews = try c.decodeIfPresent(Bool.self, forKey: .reviews) ?? true
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? true
        inReview = try c.decodeIfPresent(Bool.self, forKey: .inReview) ?? true
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case managers, jobs, reviews, active, paused, inReview, completed, archived
    }
}

/// Session switcher overlay preferences (CROW-976).
public struct SwitcherSettings: Codable, Sendable, Equatable {
    /// The binding new installs get, and the target every legacy default is
    /// migrated onto (CROW-1002). `cmd+/` is a plain modifier chord — no prefix
    /// sequence to learn, no key an agent TUI wants — so it commits on release
    /// of Cmd the way a macOS app switcher does.
    ///
    /// Non-Apple keyboards have no Cmd: set `ctrl+/` with
    /// `crow ui set --switcher-binding 'ctrl+/'`.
    public static let defaultBinding = "cmd+/"

    /// Bindings Crow refuses to use for the switcher, rewritten to
    /// `defaultBinding` on decode and rejected on write (CROW-1002).
    ///
    /// `shift+tab` is Claude Code's (and Cursor's, and Codex's) permission-mode
    /// cycle, and `captureInTerminal` defaults to true, so a config carrying it
    /// swallows that keystroke in every focused terminal. CROW-980 changed only
    /// the *default* — which reaches a config with no `binding` key at all — so
    /// every install that had already written one kept eating Shift+Tab. That is
    /// the bug CROW-1002 opens with, and a default change alone would not have
    /// fixed it a second time.
    ///
    /// Migration and validation share this set on purpose: a binding the decoder
    /// silently rewrites but the setter still accepts would revert on the next
    /// daemon start with nothing to explain why. Anything not listed here is a
    /// real choice and is left alone — `esc+tab` included, which merely stopped
    /// being the default.
    public static let reservedBindings: Set<String> = ["shift+tab"]

    /// True when `binding` names a chord Crow must not take from the terminal.
    ///
    /// Trimmed and case-folded because `--switcher-binding` stores the string
    /// verbatim and the client parses it case-insensitively, so `Shift+Tab `
    /// reaches the terminal as the same swallowed keystroke `shift+tab` does.
    public static func isReservedBinding(_ binding: String) -> Bool {
        reservedBindings.contains(binding.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public var enabled: Bool
    /// Chord string, e.g. `cmd+/` or `ctrl+space`. Parsed client-side.
    ///
    /// A leading `esc` is still accepted and parsed as a *prefix* rather than a
    /// modifier (tap Esc, then the key) — CROW-980's sequence support outlived
    /// its stint as the default.
    public var binding: String
    /// When true, the binding is captured even inside a focused terminal.
    public var captureInTerminal: Bool
    public var order: SwitcherOrder
    /// Fetch a cheap tmux pane preview for the highlighted card.
    public var preview: Bool
    public var include: SwitcherIncludeSettings

    public init(
        enabled: Bool = true,
        binding: String = SwitcherSettings.defaultBinding,
        captureInTerminal: Bool = true,
        order: SwitcherOrder = .mru,
        preview: Bool = true,
        include: SwitcherIncludeSettings = SwitcherIncludeSettings()
    ) {
        self.enabled = enabled
        self.binding = binding
        self.captureInTerminal = captureInTerminal
        self.order = order
        self.preview = preview
        self.include = include
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        binding = SwitcherSettings.migratedBinding(
            try c.decodeIfPresent(String.self, forKey: .binding))
        captureInTerminal = try c.decodeIfPresent(Bool.self, forKey: .captureInTerminal) ?? true
        order = try c.decodeIfPresent(SwitcherOrder.self, forKey: .order) ?? .mru
        preview = try c.decodeIfPresent(Bool.self, forKey: .preview) ?? true
        include = try c.decodeIfPresent(SwitcherIncludeSettings.self, forKey: .include)
            ?? SwitcherIncludeSettings()
    }

    /// Resolve a stored binding, rewriting a reserved one onto the current
    /// default (CROW-1002). Absent and blank both mean "never chose one".
    public static func migratedBinding(_ stored: String?) -> String {
        guard let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty else {
            return defaultBinding
        }
        return isReservedBinding(stored) ? defaultBinding : stored
    }

    enum CodingKeys: String, CodingKey {
        case enabled, binding, captureInTerminal, order, preview, include
    }
}
