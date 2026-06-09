#!/usr/bin/env sh
# CROW-466 spike — OSC 8 hyperlink test fixture.
#
# Print an OSC 8 sequence wrapping "Crow" with the issue URL. On a
# renderer that honors OSC 8 (SwiftTerm with linkReporting = .explicit),
# hovering shows pointing-hand cursor and clicking opens the URL.
#
# On the current libghostty embed, the link is silently dropped:
# GhosttyApp.handleAction() only dispatches SHOW_CHILD_EXITED.
printf '\e]8;;https://github.com/radiusmethod/crow/issues/466\e\\Crow #466\e]8;;\e\\\n'
