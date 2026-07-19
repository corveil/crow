---
description: Show an image in Crow's Images panel — pass the file path as the argument
---

Make the image at `$ARGUMENTS` visible in Crow's Images panel (in the session
detail pane):

1. If the `CROW_ARTIFACTS_DIR` environment variable is empty, this isn't a Crow
   session — tell the user and stop.
2. Otherwise copy `$ARGUMENTS` into `$CROW_ARTIFACTS_DIR` (create the directory
   if needed), keeping a clear filename (e.g. `diagram.png`).
3. Confirm the filename and that it now shows in Crow's Images panel.

Supported types: PNG, JPG, GIF, WEBP, SVG. The directory is ephemeral and lives
outside the git worktree.
