# Contributing to Crow

Thank you for your interest in contributing to Crow! This guide will help you get started.

Please note that this project is released with a [Code of Conduct](CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.

## Reporting Bugs

Open a [GitHub Issue](https://github.com/radiusmethod/crow/issues/new?template=bug_report.md) with:

- macOS version and hardware (Intel/Apple Silicon)
- Xcode and Zig versions
- Steps to reproduce
- Expected vs actual behavior
- Relevant stderr logs (see [Debugging](README.md#debugging))

## Suggesting Features

Open a [GitHub Issue](https://github.com/radiusmethod/crow/issues/new?template=feature_request.md) describing the use case and proposed solution.

## Development Setup

See [README.md](README.md#detailed-setup) for full build instructions. The short version:

```bash
git clone https://github.com/radiusmethod/crow.git
cd crow
make build
```

> Always use `make build` for full builds. It generates build info and runs
> the Swift build. Use `swift build` only for quick iteration after the
> initial build.

**Note:** Code signing is not required for development. Unsigned builds work normally for local testing. Official releases are signed and notarized automatically via GitHub Actions.

### Running Tests

```bash
make test         # Preferred — runs all package tests
swift test        # Also works (runs root package tests)
mise test         # If using mise
```

Tests use the Swift Testing framework (`@Test` macros). Currently, tests exist
in `CrowCore`. When adding new functionality to any package, include a test
target in that package's `Package.swift` and add tests.

## Code Style

- **Swift 6.0** with strict concurrency enabled
- **SwiftUI** for all views
- Follow existing patterns in the codebase
- Keep packages focused — each package under `Packages/` has a single responsibility

## Package Structure

New functionality should go in the appropriate existing package:

| Package | Scope |
|---------|-------|
| `CrowCore` | Data models, observable app state |
| `CrowUI` | SwiftUI views, theme |
| `CrowTerminal` | xterm.js terminal surface management |
| `CrowGit` | Git operations |
| `CrowProvider` | GitHub/GitLab provider abstraction |
| `CrowPersistence` | JSON store, config I/O |
| `CrowClaude` | Claude binary resolution |
| `CrowIPC` | Unix socket RPC protocol |

If a new package is needed, create it under `Packages/` and add it to the root `Package.swift`.

## Pull Requests

1. Fork the repo and create a feature branch from `main`
2. Make your changes with clear, focused commits
3. Include tests for new functionality where applicable
4. Ensure `swift test` passes
5. Open a PR with:
   - A description of what changed and why
   - A link to the related issue
   - Screenshots for UI changes

## Architecture Decision Records

Decisions that will outlive a single PR — defaults, contracts, architecture choices, or anything a new contributor or agent would want to find by grep — get recorded as ADRs under [`docs/adr/`](docs/adr/). Copy [`docs/adr/template.md`](docs/adr/template.md), give it the next 4-digit sequence number, fill in `Context` / `Decision` / `Consequences` / `Alternatives considered`, and add a row to the index in [`docs/adr/README.md`](docs/adr/README.md). PR descriptions are still where you explain *this change*; ADRs are where you explain *the decision* that change is implementing.

When superseding an existing ADR, leave the old file in place and update its `Status` field to `Superseded by NNNN`. We keep the trail.

## Versioning

Crow follows [Semantic Versioning](https://semver.org/):

- **Major** (X.0.0) — breaking changes to the CLI, IPC protocol, or config format
- **Minor** (0.X.0) — new features and capabilities
- **Patch** (0.0.X) — bug fixes and minor improvements

### Version source of truth

The `VERSION` file at the repo root contains the current version (e.g., `0.1.0`). All build scripts read from this file. Never hardcode a version string elsewhere.

For CI, set the `CROW_VERSION` environment variable to override the file. The build number (`CFBundleVersion`) is derived automatically from `git rev-list --count HEAD`.

### Releasing a new version

1. Update `VERSION` with the new version number
2. Move entries from `[Unreleased]` in `CHANGELOG.md` into a new version section
3. Commit: `git commit -am "Release vX.Y.Z"`
4. Tag: `git tag vX.Y.Z`
5. Push: `git push origin main --tags`

### Changelog contributions

When submitting a PR, add a bullet under the `[Unreleased]` section of `CHANGELOG.md` describing your change. Use the categories from [Keep a Changelog](https://keepachangelog.com/): Added, Changed, Deprecated, Removed, Fixed, Security.

### Future considerations

We may adopt [Conventional Commits](https://www.conventionalcommits.org/) and automated changelog generation (e.g., [git-cliff](https://git-cliff.org/)) as the project matures. For now, the changelog is maintained manually.

## Auto-Scaffolded Files

Crow auto-generates certain files into `{devRoot}/.claude/` on launch (see `Scaffolder.swift`):

- `CLAUDE.md` — scaffolded from the root `CLAUDE.md`
- `skills/crow-workspace/SKILL.md` — scaffolded from `Resources/crow-workspace-SKILL.md.template`
- `settings.local.json` — merged with pre-approved permissions on every launch; `settings.json` is the user's own file and Crow never writes it

**Do not edit the scaffolded copies.** Instead, modify the source files in the repository root or `Resources/` directory.
