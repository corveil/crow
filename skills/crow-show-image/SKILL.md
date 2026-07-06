---
name: crow-show-image
description: >-
  Surface an image you've generated (a diagram, chart, screenshot, or
  rendered figure) in Crow's Images panel so the user can see it inline.
  Use whenever you produce a visual artifact worth showing.
---

# Crow: Show Image

Make an image you've generated visible in Crow's Images panel (in the session
detail), so the user sees it inline instead of just a file path.

## When to use

Use this when you've produced an image the user should see — a diagram you
drew, a chart, a screenshot, a rendered figure. Skip it for throwaway or
intermediate images the user didn't ask about.

Only works inside a Crow session, where `CROW_ARTIFACTS_DIR` is set.

## How

1. Confirm you're in a Crow session — `CROW_ARTIFACTS_DIR` must be non-empty.
   If it's unset, there's no Crow panel to show it in; skip this.
2. Copy the image into that directory (create it if needed), with a clear
   name:

   ```bash
   mkdir -p "$CROW_ARTIFACTS_DIR" && cp <image> "$CROW_ARTIFACTS_DIR/<name>.png"
   ```

3. Tell the user it's viewable in Crow's Images panel.

Supported: PNG, JPG, GIF, WEBP, SVG. The directory is ephemeral (cleared on
restart) and lives outside the git worktree, so it never pollutes commits.
