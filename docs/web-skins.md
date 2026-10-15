# Web UI skins

CROW-1333 (built-ins), CROW-1334 (custom skins and `crow skin`). The browser UI `crowd` serves is painted from a fixed set of CSS
variables. A **skin** fills those variables; **Theme** (System / Light / Dark)
picks which half of the skin applies. Both are chosen in Settings → General and
saved per browser, not in daemon config.

## Built-in skins

| id | Name | Modes | Notes |
|---|---|---|---|
| `corveil` | Corveil | light + dark | The default. It *is* `theme.css`; it has no generated CSS. |
| `corveil-classic` | Corveil Classic | dark only | The pre-#1317 gold-on-charcoal look, system UI font, xterm's stock ANSI palette on `#1E1E1E`. Muted text, accent-muted, red, blue and purple are lifted slightly from the old values so they clear 4.5:1. |
| `graphite` | Graphite | light + dark | Neutral grays, one muted slate-blue accent, system UI font. |

They live in `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/skins/<id>.json`.

## Make a skin

Custom skins are the same JSON files, kept in
`~/Library/Application Support/crow/skins/<id>.json` (the platform's
Application Support directory on Linux). They show up in the Settings picker
next to the built-ins, marked *custom*, and in `crow skin list`. The fastest
way to make one is to start from an existing skin:

```bash
crow skin create --from corveil-classic --name "Dusty" --set accent=#7AA2F7
crow skin create --from graphite --name "Warm" --set accent=#D9A55B --set-light accent=#8A5A14
```

`--set` writes the dark palette and `--set-light` the light one; a token may
drop its leading dashes. To edit by hand, export a complete file (every token,
resolved against Corveil), change it, and add it back under a new id:

```bash
crow skin export --id graphite --out ~/skins/mine.json
$EDITOR ~/skins/mine.json            # set "id" and "name", change tokens
crow skin add ~/skins/mine.json
```

Rules for a custom skin:

- Its id may not be a built-in's, and built-ins cannot be removed.
- Every key must be a token from the table below; every token except the four
  `--shadow-*` must hold a color (a literal, `var()`, a color function such as
  `color-mix()`/`hsl()`, or a named color). An invalid skin is refused.
- **Contrast is a warning, not a gate.** Text and status tokens below 4.5:1 on
  the four surfaces, `--on-accent`/`--on-green`/`--on-red` below 4.5:1 on their
  fills, `--term-fg` below 4.5:1 on `--term-bg`, and the terminal scroll thumb
  below 3:1 are reported with the measured ratio, and the skin is saved anyway.

Changes are live: crowd re-reads the store on every request, and open tabs
poll `/skins.json`'s `revision` every ~10 seconds (and when the tab becomes
visible). A browser whose skin is removed falls back to the default.

`crow skin default set <id>` makes a skin the default for every browser that
hasn't picked one (`webDefaultSkin` in `config.json`); the picker's first
entry, **Default (…)**, follows it. `crow skin default clear` returns it to
Corveil. The full verb reference is in `docs/cli-reference.md`.

## Format

```json
{
  "id": "graphite",
  "name": "Graphite",
  "dark":  { "--bg-deep": "#111214", "--accent": "#8AA4C8" },
  "light": { "--bg-deep": "#F4F5F7", "--accent": "#3B5B86" },
  "fonts": { "ui": "system-ui, sans-serif", "mono": "ui-monospace, monospace" }
}
```

- `id`: lowercase letters, digits and dashes, at most 64. The file is named `<id>.json`.
- `dark` is required (it may be empty). `light` is optional: a skin without it
  is **dark only**, and the web UI pins the dark theme and disables Light while
  it is selected.
- Every key must be one of the tokens below. A key the skin leaves out falls
  back to the Corveil value in `theme.css`.
- `--term-*` values must be literal colors (`#rgb`, `#rrggbb`, `#rrggbbaa`,
  `rgb()`/`rgba()`), never `var()`: xterm reads them from JS.
- Values may not contain `;` `{` `}` `<` `>` `\` `@`, comments, or `url()`. An
  invalid skin is skipped by `crowd`, not served.

The model and validator are `WebSkin` in CrowCore.

## Tokens

The brand primitives at the top of `theme.css` (`--ink-*`, `--plum-900`,
`--pink*`, `--paper*`, `--brand-text`) are constants the Corveil palette is
built from, not skin tokens. Fonts are set through `fonts`, not as tokens.

| Group | Tokens |
|---|---|
| Fills and their text | `--accent-fill` `--on-accent` `--green-fill` `--on-green` `--red-fill` `--on-red` |
| Scrims and elevation | `--overlay` `--overlay-strong` `--shadow-raised` `--shadow-card` `--shadow-popover` `--shadow-modal` |
| Surfaces | `--bg-deep` `--bg-surface` `--bg-card` `--bg-elev` `--bg-elevated` `--bg-selected` `--bg-done` |
| Lines | `--border-subtle` `--border-strong` |
| Text | `--text-primary` `--text-secondary` `--text-muted` |
| Accent | `--accent` `--accent-muted` `--accent-soft` `--accent-wash` `--accent-line` `--attention-wash` |
| Washes | `--skel-lo` `--skel-hi` `--skel-still` `--badge-wash` |
| Status text | `--green` `--yellow` `--orange` `--red` `--blue` `--purple` |
| Scorecard grades | `--grade-a` … `--grade-f` |
| Terminal | `--term-bg` `--term-fg` `--term-cursor` `--term-cursor-accent` `--term-selection`, the 16 ANSI colors `--term-black` … `--term-bright-white`, `--term-hud-bg` |
| Terminal scrollbar | `--scroll-thumb` `--scroll-thumb-hover` `--scroll-thumb-active` |

`--accent-soft`, `--accent-wash`, `--accent-line`, `--attention-wash` and the
washes are `color-mix()`es of other tokens in `theme.css`, so a skin usually
leaves them alone and they follow its `--accent` / `--text-muted`.

No color literal may appear in the web UI outside `theme.css` and the skin
files, except the initial `<meta name="theme-color">` in `index.html` and
`login.html` (and `manifest.webmanifest`), which are fixed before any CSS loads.

## Contrast

Every built-in skin, in every mode it has, keeps text, accent and status tokens
at 4.5:1 or better on `--bg-deep`, `--bg-surface`, `--bg-card` and `--bg-elev`;
`--on-accent` at 4.5:1 on `--accent-fill`; and the terminal scroll thumb at
3:1 on `--term-bg` (WCAG 2.2 §1.4.11).

## How it is served and applied

- `GET /skins.json` — `{"default":"corveil","revision":"…","skins":[{id,name,light,builtin}]}`.
  `default` is the daemon-wide default; `revision` changes whenever a skin is
  added, edited or removed or the default moves.
- `GET /skins/<id>.css` — the skin as CSS, scoped to `:root[data-skin="<id>"]`
  (dark rules add `:not([data-theme="light"])`, light rules
  `[data-theme="light"]`), so it outranks `theme.css` only where it sets a value.
- Both, plus `theme.js`, are auth-exempt so the login page paints in the chosen skin.
- `theme.js` (blocking, in `<head>`) stores `crow.skin` and caches the last
  CSS in `crow.skin.cache`. On load it injects the cached CSS and stamps
  `data-skin` synchronously, so a reload never flashes Corveil; after
  `DOMContentLoaded` it refetches in case the file changed, then polls the
  catalog's `revision`. A chosen skin `crowd` no longer offers is dropped and
  the browser follows the default; no stored choice means the default too
  (remembered in `crow.skin.default` so it paints before the fetch).
- Switching fires `crow-theme`; terminals re-read `crowXtermTheme()` on it, so
  live terminals recolor with no reload.

## Adding a token

Add it to `theme.css` (both blocks if it differs in light), to `WebSkin.tokens`
in CrowCore, and to the table above. `WebSkinTests` fails while `theme.css` and
`WebSkin.tokens` disagree.
