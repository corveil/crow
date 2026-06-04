#!/usr/bin/env bash
# crow-shell-wrapper — installs prompt-ready markers, then exec's the user's $SHELL.
#
# Bundled with Crow.app, copied to a temp path at terminal create time. The
# Crow app sets CROW_SENTINEL in the env (per-terminal) before exec'ing this
# script. Each prompt firing touches that file, which the Swift readiness
# detector polls. Optional CROW_WRAPPER_LOG points at a per-terminal log file
# the wrapper appends stage breadcrumbs to (issue #256) — Swift surfaces it
# on .timedOut so a teammate can copy a one-clipboard diagnostic bundle.
#
# This wrapper is intentionally minimal:
#   1. Source the user's normal shell startup (zsh: .zshrc; bash: .bashrc) so
#      aliases / oh-my-zsh / asdf / nvm / starship keep working.
#   2. Install a precmd (zsh) or PROMPT_COMMAND (bash) hook that:
#        - emits OSC 133;A (FinalTerm prompt-start marker)
#        - emits a custom OSC 9;crow-ready marker (Crow-specific)
#        - touches $CROW_SENTINEL so Swift can poll without parsing output
#      When running under tmux, OSCs are wrapped in the DCS-tmux passthrough
#      envelope (\ePtmux;\e<seq>\e\\) so they survive tmux's emulator. The
#      bundled tmux.conf sets `allow-passthrough on` to make this work.
#   3. Preserve any pre-existing precmd / PROMPT_COMMAND.
#   4. Hand off via `exec "$SHELL" -i` so the shell sits at the same process
#      depth it would in any other terminal — no extra layer.

# CROW_SENTINEL must be set by the caller (Crow app or tmux new-window -e).
if [ -z "${CROW_SENTINEL:-}" ]; then
  echo "crow-shell-wrapper: CROW_SENTINEL env var is required" >&2
  exit 64
fi
export CROW_SENTINEL

# Agent attribution (issue #443). Crow sets these via tmux new-window -e.
if [ -n "${CROW_AGENT_KIND:-}" ]; then export CROW_AGENT_KIND; fi
if [ -n "${CROW_AGENT_DISPLAY_NAME:-}" ]; then export CROW_AGENT_DISPLAY_NAME; fi

# CROW_WRAPPER_LOG is optional. Default to /dev/null so the helper is always
# safe to call without an unset-var guard. Issue #256.
CROW_WRAPPER_LOG="${CROW_WRAPPER_LOG:-/dev/null}"
export CROW_WRAPPER_LOG

crow_log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$CROW_WRAPPER_LOG" 2>/dev/null || true
}

# Opt-in verbose tracing for hard-to-repro setup bugs. Routes shell xtrace to
# the same log file (issue #256).
if [ "${CROW_WRAPPER_DEBUG:-}" = "1" ] && [ "$CROW_WRAPPER_LOG" != "/dev/null" ]; then
  exec 2>>"$CROW_WRAPPER_LOG"
  set -x
fi

if [ -z "${SHELL:-}" ]; then SHELL=/bin/zsh; fi

crow_log "start pid=$$ shell=$SHELL tmux=${TMUX:+yes} sentinel=$CROW_SENTINEL log=$CROW_WRAPPER_LOG"

# Cross-check $SHELL against directory services. Mismatch can mean the user
# chsh'd to a brew-installed shell but the parent process inherited an old
# $SHELL — surfacing this in the log helps diagnose the case in issue #256 §4.
# We do NOT override $SHELL; just record the discrepancy.
if command -v dscl >/dev/null 2>&1 && [ -n "${USER:-}" ]; then
  _crow_dscl_shell=$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')
  if [ -n "$_crow_dscl_shell" ] && [ "$_crow_dscl_shell" != "$SHELL" ]; then
    crow_log "shell_mismatch env_shell=$SHELL dscl_shell=$_crow_dscl_shell"
  fi
  unset _crow_dscl_shell
fi

case "$SHELL" in
  *zsh)
    # zsh: we can't directly modify the user's .zshrc — instead, point ZDOTDIR
    # at a temp dir whose .zshrc sources the user's real config, then appends
    # our hook via add-zsh-hook (which composes with any existing precmd).
    ZTMP="$(mktemp -d -t crowzdotdir)"
    if [ -z "$ZTMP" ] || [ ! -d "$ZTMP" ]; then
      crow_log "mktemp_failed branch=zsh status=$?"
      echo "crow-shell-wrapper: mktemp -d failed for zsh ZDOTDIR" >&2
      exit 73
    fi
    crow_log "zdotdir_temp_created path=$ZTMP"
    cat > "$ZTMP/.zshrc" <<'ZRC'
# Helper redefined inside the embedded rc — it runs in the new shell, so it
# needs its own crow_log. Same file the wrapper appends to (issue #256).
crow_log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${CROW_WRAPPER_LOG:-/dev/null}" 2>/dev/null || true; }

# Source the user's real config from their original ZDOTDIR (or $HOME).
if [ -n "${CROW_USER_ZDOTDIR:-}" ]; then
  ZDOTDIR="$CROW_USER_ZDOTDIR"
else
  ZDOTDIR="$HOME"
fi
if [ -f "$ZDOTDIR/.zshrc" ]; then
  source "$ZDOTDIR/.zshrc"
  crow_log "user_rc_sourced rc=$ZDOTDIR/.zshrc"
else
  crow_log "user_rc_skipped reason=missing rc=$ZDOTDIR/.zshrc"
fi

_crow_precmd() {
  crow_log "precmd_fired"
  if [ -n "${TMUX:-}" ]; then
    printf '\033Ptmux;\033\033]133;A\007\033\\'
    printf '\033Ptmux;\033\033]9;crow-ready\007\033\\'
  else
    printf '\033]133;A\007'
    printf '\033]9;crow-ready\007'
  fi
  if : > "$CROW_SENTINEL" 2>>"${CROW_WRAPPER_LOG:-/dev/null}"; then
    crow_log "sentinel_written"
  else
    crow_log "sentinel_write_failed status=$?"
  fi
  # Self-disarm logging after first prompt so we don't bloat the log on every
  # subsequent prompt (issue #256).
  crow_log() { :; }
}

if autoload -Uz add-zsh-hook 2>/dev/null; then
  add-zsh-hook precmd _crow_precmd
  crow_log "hook_installed mechanism=add-zsh-hook"
else
  crow_log "add_zsh_hook_unavailable"
fi
# Belt-and-braces (issue #256 §4): covers the case where a deferred plugin
# reassigns precmd_functions=(...) after our install. add-zsh-hook already
# dedupes, so this is safe even when the hook is already registered.
if (( ${precmd_functions[(I)_crow_precmd]:-0} == 0 )); then
  precmd_functions+=(_crow_precmd)
  crow_log "hook_installed mechanism=precmd_functions_append"
fi
ZRC
    crow_log "pre_exec shell=$SHELL"
    CROW_USER_ZDOTDIR="${ZDOTDIR:-$HOME}" ZDOTDIR="$ZTMP" exec "$SHELL" -i
    ;;
  *bash)
    BTMP="$(mktemp -t crowbashrc.XXXXXX)"
    if [ -z "$BTMP" ] || [ ! -f "$BTMP" ]; then
      crow_log "mktemp_failed branch=bash status=$?"
      echo "crow-shell-wrapper: mktemp failed for bash rcfile" >&2
      exit 73
    fi
    crow_log "zdotdir_temp_created path=$BTMP"
    cat > "$BTMP" <<'BRC'
crow_log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${CROW_WRAPPER_LOG:-/dev/null}" 2>/dev/null || true; }
if [ -f "$HOME/.bashrc" ]; then
  source "$HOME/.bashrc"
  crow_log "user_rc_sourced rc=$HOME/.bashrc"
else
  crow_log "user_rc_skipped reason=missing rc=$HOME/.bashrc"
fi
_crow_precmd() {
  crow_log "precmd_fired"
  if [ -n "${TMUX:-}" ]; then
    printf '\033Ptmux;\033\033]133;A\007\033\\'
    printf '\033Ptmux;\033\033]9;crow-ready\007\033\\'
  else
    printf '\033]133;A\007'
    printf '\033]9;crow-ready\007'
  fi
  if : > "$CROW_SENTINEL" 2>>"${CROW_WRAPPER_LOG:-/dev/null}"; then
    crow_log "sentinel_written"
  else
    crow_log "sentinel_write_failed status=$?"
  fi
  crow_log() { :; }
}
# Preserve any existing PROMPT_COMMAND.
if [ -n "${PROMPT_COMMAND:-}" ]; then
  PROMPT_COMMAND="_crow_precmd; $PROMPT_COMMAND"
else
  PROMPT_COMMAND="_crow_precmd"
fi
crow_log "hook_installed mechanism=PROMPT_COMMAND"
BRC
    crow_log "pre_exec shell=$SHELL"
    exec "$SHELL" --rcfile "$BTMP" -i
    ;;
  *)
    # fish / unknown: best-effort. Emit markers once at startup; no per-prompt
    # hook. Production work would extend this with shell-specific paths.
    crow_log "hook_skipped reason=unsupported_shell shell=$SHELL"
    if [ -n "${TMUX:-}" ]; then
      printf '\033Ptmux;\033\033]133;A\007\033\\\033Ptmux;\033\033]9;crow-ready\007\033\\'
    else
      printf '\033]133;A\007\033]9;crow-ready\007'
    fi
    if : > "$CROW_SENTINEL" 2>>"${CROW_WRAPPER_LOG:-/dev/null}"; then
      crow_log "sentinel_written"
    else
      crow_log "sentinel_write_failed status=$?"
    fi
    crow_log "pre_exec shell=$SHELL"
    exec "$SHELL" -i
    ;;
esac
