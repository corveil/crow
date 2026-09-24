import Foundation
import CrowCore
import CrowProvider

// MARK: - Review clone preparation (CROW-1302)
//
// Off-main-actor `prepareReviewClone`: clone (or reuse), restore-before-pull,
// fetch/checkout/pull, then strip-after-pull for the reviewing agent only,
// then write the prompt, the skill copy (frontmatter kept), and bundled
// `settings.json` (removed first, fail-closed). Clone failure and a missing
// prompt file throw; `git fetch` / `checkout` / `pull` stay `try?`-swallowed.
extension ReviewSessionController {
    /// Off-main-actor preparation for a review session: fetch PR metadata,
    /// clone the repo (if needed), check out the PR branch, and stage the
    /// review prompt / skill / settings files. Returns the metadata the
    /// main-actor portion of `createReviewSession` needs. Throws on the only
    /// failure that should abort kickoff entirely (PR metadata fetch). git
    /// fetch/checkout/pull errors are tolerated as before — the worktree may
    /// already be in a usable state from a prior run. Internal (not
    /// `private`) so `createReviewSession` in `ReviewSessionController`
    /// can call it — Swift `private` is file-scoped (CROW-1302).
    internal nonisolated static func prepareReviewClone(
        prURL: String,
        repoSlug: String,
        repoName: String,
        prNumber: Int,
        devRoot: String,
        env: [String: String],
        reviewAgentKind: AgentKind,
        reviewBlocking: [ReviewSeverity] = ReviewSeverity.defaultBlocking,
        prMetadata: PRMetadata
    ) async throws -> ReviewClonePrep {
        let prTitle = prMetadata.title
        let headBranch = prMetadata.headRefName
        guard !headBranch.isEmpty else {
            throw NSError(
                domain: "SessionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "PR metadata missing headRefName for \(prURL)"]
            )
        }
        // `headRefOid` is the SHA the review session is anchored to. Used by
        // the kickoff guard (AppDelegate) as a fallback re-kick signal when
        // the PR head advances without an explicit re-request (CROW-290).
        let headRefOid: String? = prMetadata.headRefOid.isEmpty ? nil : prMetadata.headRefOid

        let reviewsDir = DevRootLayout.reviewsDir(devRoot: devRoot)
        let cloneDirName = "\(repoName)-pr-\(prNumber)"
        let clonePath = (reviewsDir as NSString).appendingPathComponent(cloneDirName)

        let fm = FileManager.default

        // Ensure reviews directory exists
        try? fm.createDirectory(atPath: reviewsDir, withIntermediateDirectories: true)

        // Clone or update the repo. Clone failures MUST surface (CROW-439): if
        // the checkout directory never gets created, the launcher would still
        // build a `agent "$(cat .crow-review-prompt.md)"` command pointing at a
        // path that doesn't exist, and the agent would launch with an empty
        // prompt. Throwing here aborts session creation cleanly.
        if !fm.fileExists(atPath: (clonePath as NSString).appendingPathComponent(".git")) {
            CrowLog.info("[SessionService] Cloning \(repoSlug) into \(clonePath)")
            do {
                _ = try await SessionService.runShellAsync(env: env, args: ["gh", "repo", "clone", repoSlug, clonePath])
            } catch {
                throw NSError(
                    domain: "SessionService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to clone \(repoSlug) into \(clonePath): \(error.localizedDescription)"]
                )
            }
        }

        // Defense-in-depth: clone may have "succeeded" (exit 0) but left the
        // directory in an unusable state. Refuse to proceed if the path isn't
        // a real directory.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: clonePath, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(
                domain: "SessionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Clone path \(clonePath) does not exist after clone step"]
            )
        }

        // Fetch and checkout the PR branch. These are best-effort: the existing
        // working tree may already be on the right branch, and a network blip
        // on `pull` shouldn't abort the launch — the agent can resume from the
        // local state.
        //
        // Restore `.codex` first, but only for Codex reviews (see the strip
        // below): a *re-prep* of this same clone dir starts with the prior
        // prep's `.codex` strip still applied as an unstaged deletion of tracked
        // files, which would make `git pull` refuse ("local changes would be
        // overwritten") if the new head touches `.codex/` — silently reviewing a
        // stale head. Restoring before the pull keeps the tree clean; the strip
        // below re-applies afterward (#843 review round 6).
        if reviewAgentKind == .codex {
            _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", ".codex"])
        }
        // Same restore-before-pull for Cursor reviews (#829 review round 9):
        // the `.cursor/` strip below applies as an unstaged deletion of tracked
        // files, so `git pull` would refuse if the new head touches `.cursor/`.
        if reviewAgentKind == .cursor {
            _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", ".cursor"])
        }
        // Same restore-before-pull for Grok reviews (#859, extended #861 rounds
        // 2-3, r12): Grok's strip below neutralizes *every* project source Grok
        // discovers (`.grok/`, `.cursor/`, **both** `.claude/settings.json` and
        // `settings.local.json`, repo-root `.mcp.json`), each applied as an
        // unstaged deletion of tracked files — so restore all of them before the
        // pull, or `git pull` refuses when the new head touches any.
        if reviewAgentKind == .grok {
            for path in [".grok", ".cursor", ".claude/settings.json", ".claude/settings.local.json", ".mcp.json"] {
                _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", path])
            }
        }
        // Same restore-before-pull for Antigravity reviews (#902 review): the
        // strip below applies as an unstaged deletion of tracked files.
        // A fast-forward `git pull` silently restores the deleted paths (verified),
        // but a non-fast-forward merge that touches them refuses ("local changes
        // would be overwritten"); since the pull is `try?`-swallowed, that would
        // leave the clone at the stale head while `.crow-review-prompt.md` is
        // rewritten with the current PR URL. Restore both stripped layers
        // (`.agents/` **and** `.gemini/`, #902 review r7) first, for parity with the
        // `.codex`/`.cursor`/`.grok` arms and clean re-prep. This is re-prep
        // hygiene, NOT the security boundary: the load-bearing defense is the strip
        // in `prepareWorktreeForAgentLaunch`, which re-fires on every launch after
        // the SKILL's `gh pr checkout` may have restored a committed layer.
        if reviewAgentKind == .antigravity {
            for path in [".agents", ".gemini"] {
                _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", path])
            }
        }
        // Same restore-before-pull for Muse reviews (#1033): the strip below
        // applies as an unstaged deletion of `.muse/` + `.agents/`. Restore
        // first so `git pull` cannot refuse when the new head touches them.
        if reviewAgentKind == .muse {
            for path in [".muse", ".agents"] {
                _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", path])
            }
        }
        _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "fetch", "origin", headBranch])
        _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", headBranch])
        _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "pull", "origin", headBranch])

        // Defense-in-depth for Codex reviews (#843 review round 5): strip any
        // committed `.codex/` from the checked-out PR head before the agent
        // launches. The head is attacker-controlled and `.codex/hooks.json` /
        // inline `[hooks]` in `.codex/config.toml` are not conventionally
        // gitignored, so a drive-by PR could ship hooks that Codex would run
        // once the folder is trusted. `launchAgent` already declines to trust a
        // review clone; removing the config layer here means the hooks can't
        // fire even if the folder is trusted by some other path (a globally
        // pre-trusted parent, a manual handoff). Re-run on every prep so a
        // `git pull` on the reused clone dir can't reintroduce it. Mirrors the
        // Claude path's `.claude/settings.json` overwrite below.
        //
        // Gated to Codex reviews (#843 review round 7): only Codex loads
        // `.codex/`, so stripping it for a Claude/Cursor/OpenCode review would
        // just hide from the reviewing agent the exact files a hostile PR ships
        // — the review surface should stay intact for the agents that don't act
        // on `.codex/`.
        if reviewAgentKind == .codex {
            try? fm.removeItem(atPath: (clonePath as NSString).appendingPathComponent(".codex"))
        }
        // Defense-in-depth for Antigravity review clones (#862 review, #902): a
        // hostile PR head can commit `.agents/hooks.json` with arbitrary command
        // hooks that `agy` runs with no approval gate. Now that Antigravity
        // supports review (`autoLaunchCommand(.review)` dispatches the inlined
        // SKILL), this strip is load-bearing — and because `agy` has no trust
        // gate, `stripAntigravityConfigFromReviewClone` is also wired into
        // `prepareWorktreeForAgentLaunch` (every launch path), so the review
        // skill's `gh pr checkout` / a head-advancing re-review can't restore the
        // hooks for the next `agy` launch. Gated to Antigravity reviews for the
        // same reason as `.codex`/`.cursor`: only Antigravity loads `.agents/`, so
        // stripping it for another agent's review would just hide the files a
        // hostile PR ships. Re-run on every prep so a `git pull` can't
        // reintroduce it.
        if reviewAgentKind == .antigravity {
            Self.stripAntigravityConfigFromReviewClone(clonePath: clonePath)
        }
        // Defense-in-depth for Muse review clones (#1033): withhold
        // `--trust-workspace` so project hooks/skills/rules do not load, and
        // strip `.muse/` + `.agents/` (memory loads even untrusted). The
        // launch-path strip in `prepareWorktreeForAgentLaunch` is load-bearing
        // — the review skill's `gh pr checkout` can restore a committed layer.
        if reviewAgentKind == .muse {
            Self.stripMuseConfigFromReviewClone(clonePath: clonePath)
        }
        // Defense-in-depth for Grok reviews (#859, extended #861 rounds 2-3, r12):
        // Grok discovers & merges project config from `.grok/hooks/*.json`,
        // `.claude/settings.json` + `settings.local.json`, `.cursor/hooks.json`,
        // and project MCP servers from `.cursor/mcp.json` +
        // `.grok/config.toml` + repo-root `.mcp.json` — `compat.*.hooks = true`
        // by default. On an attacker-controlled review head each is
        // arbitrary-command RCE once the folder is trusted, and the strip is the
        // durable guard (dev builds trust everything; a trusted parent cascades
        // on release). `stripGrokConfigFromReviewClone` neutralizes the full set
        // (`.grok/` + `.cursor/` + `.claude/settings{,.local}.json` + `.mcp.json`);
        // `.claude/settings.json` is re-written bundled-safe below at creation, and
        // left absent on the launch-time re-strip paths, which is safe. This is the
        // creation-time strip; every launch-time strip runs via the shared
        // `prepareWorktreeForAgentLaunch` gate (grep its call sites), so the set of
        // paths can't drift out of sync with a stale count here.
        if reviewAgentKind == .grok {
            Self.stripGrokConfigFromReviewClone(clonePath: clonePath)
        }
        // Same defense-in-depth for Cursor reviews (#829 review round 9). This
        // PR makes project `.cursor/hooks.json` Crow's load-bearing hook
        // transport and adds `--force --approve-mcps` on the `.review` path, so
        // a hostile PR head's committed `.cursor/hooks.json` (arbitrary
        // `beforeShellExecution`/`beforeSubmitPrompt` commands) OR `.cursor/mcp.json`
        // (a project-scope MCP server that `--approve-mcps` would auto-trust)
        // would run on the reviewer's machine, unsandboxed, once Cursor loads
        // the clone as its project root. Gated to Cursor reviews for the same
        // reason as `.codex/`: stripping it for an agent that doesn't load it
        // would just hide the files a hostile PR ships. The strip is a
        // working-tree removal — see `stripCursorConfigFromReviewClone` for why
        // this doesn't (and needn't) free `writeHookConfig` to write into a
        // committed hooks file.
        if reviewAgentKind == .cursor {
            Self.stripCursorConfigFromReviewClone(clonePath: clonePath)
        }

        // Render the workspace's verdict policy into the SKILL body ONCE, here,
        // before the two launch paths diverge (CROW-963). Both consumers below
        // take `policySkillBody`: the inlined prompt (Cursor/OpenCode/Codex/Grok/
        // Antigravity, via `buildReviewPrompt`) and the copied `.claude/skills/…/
        // SKILL.md` (Claude). Hooking only the file copy would leave every
        // inlining agent on the default rule — and `agentsByKind.review` is
        // commonly Cursor, so that failure mode is the normal case, not an edge
        // one. `expandSkillBody` runs the same expansion again downstream with the
        // default set; it is idempotent, so that pass finds no placeholders left.
        let policySkillBody = ReviewVerdictPolicy.expand(
            Scaffolder.bundledReviewSkill(), blocking: reviewBlocking)

        // Write review prompt file into the clone directory. Write failures
        // MUST surface (CROW-439): the launcher's prompt-file shell substitution
        // substitution will yield an empty string and the agent will idle if
        // the file isn't there.
        let promptPath = (clonePath as NSString).appendingPathComponent(".crow-review-prompt.md")
        let reviewPrompt = Self.buildReviewPrompt(prURL: prURL, prTitle: prTitle, repoSlug: repoSlug, prNumber: prNumber, agentKind: reviewAgentKind, skillBody: policySkillBody)
        try reviewPrompt.write(toFile: promptPath, atomically: true, encoding: .utf8)
        guard fm.fileExists(atPath: promptPath) else {
            throw NSError(
                domain: "SessionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Review prompt file missing at \(promptPath) after write"]
            )
        }

        // Copy the crow-review-pr skill into the clone's .claude/skills/ so Claude Code can find it.
        // Substitute `{{CROW_AGENT_DISPLAY_NAME}}` before writing so the attribution footer is a
        // literal string regardless of how the agent quotes the body (issue #447 — single-quoted
        // heredocs in gh/glab calls don't expand shell variables). The verdict policy is already
        // rendered into `policySkillBody` above (CROW-963).
        //
        // This copy keeps its YAML frontmatter — Claude Code's skill engine needs the
        // `name`/`description` block to load it at all. Only the *inlined* prompt written
        // above is frontmatter-stripped (`cursorReviewPrompt`, CROW-968); don't be tempted
        // to hoist that strip up to `policySkillBody`, which would break this file.
        let cloneSkillsDir = (clonePath as NSString).appendingPathComponent(".claude/skills/crow-review-pr")
        try? fm.createDirectory(atPath: cloneSkillsDir, withIntermediateDirectories: true)
        let resolvedSkillContent = CrowAttribution.expandSkillBody(policySkillBody, agentKind: reviewAgentKind)
        try? resolvedSkillContent.write(
            toFile: (cloneSkillsDir as NSString).appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        // (Re)write `.claude/settings.json` with Crow's bundled-safe permissions
        // at creation. `stripGrokConfigFromReviewClone` above already removed any
        // committed `settings.json` for Grok reviews (Grok, like Claude, loads it
        // via compat — hooks + `env` run subprocesses, #861 review r12); this is
        // what gives the fresh clone a valid Crow-owned one, for Claude and Grok
        // reviews alike. **Fail closed** (#861 review round 4, Yellow): remove any
        // file FIRST, then write, so a write failure can't leave a stale/attacker
        // file — and make a real write failure audible. NB the two Grok re-strip
        // paths (`launchAgent`/handoff) do NOT re-run this write: there a restored
        // hostile `settings.json` is removed and left absent, which is safe — Grok
        // just falls back to no compat settings.
        let cloneSettingsDir = (clonePath as NSString).appendingPathComponent(".claude")
        let settingsPath = (cloneSettingsDir as NSString).appendingPathComponent("settings.json")
        removeReviewCloneConfig(settingsPath, label: ".claude/settings.json", clonePath: clonePath)
        let settingsContent = Scaffolder.bundledSettings()
        do {
            try fm.createDirectory(atPath: cloneSettingsDir, withIntermediateDirectories: true)
            try settingsContent.write(toFile: settingsPath, atomically: true, encoding: .utf8)
        } catch {
            CrowLog.error("[SessionService] Failed to write bundled .claude/settings.json to review clone \(clonePath): \(error.localizedDescription) (any committed file was already removed — fail-closed)")
        }

        return ReviewClonePrep(
            prTitle: prTitle,
            headBranch: headBranch,
            headRefOid: headRefOid,
            clonePath: clonePath
        )
    }
}
