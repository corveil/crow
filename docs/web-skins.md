# Web UI skins

CROW-1333. The browser UI `crowd` serves is painted from a fixed set of CSS
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

- `GET /skins.json` — `{"default":"corveil","skins":[{id,name,light}]}`.
- `GET /skins/<id>.css` — the skin as CSS, scoped to `:root[data-skin="<id>"]`
  (dark rules add `:not([data-theme="light"])`, light rules
  `[data-theme="light"]`), so it outranks `theme.css` only where it sets a value.
- Both, plus `theme.js`, are auth-exempt so the login page paints in the chosen skin.
- `theme.js` (blocking, in `<head>`) stores `crow.skin` and caches the last
  CSS in `crow.skin.cache`. On load it injects the cached CSS and stamps
  `data-skin` synchronously, so a reload never flashes Corveil; after
  `DOMContentLoaded` it refetches in case the file changed. A skin `crowd` no
  longer offers falls back to Corveil.
- Switching fires `crow-theme`; terminals re-read `crowXtermTheme()` on it, so
  live terminals recolor with no reload.

## Adding a token

Add it to `theme.css` (both blocks if it differs in light), to `WebSkin.tokens`
in CrowCore, and to the table above. `WebSkinTests` fails while `theme.css` and
`WebSkin.tokens` disagree.
