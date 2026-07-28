#!/usr/bin/env bash
# The floating pane's process: a normal interactive login shell.
#
# floax's defining behavior is a session that survives toggling. The toggle
# hides the pane by closing it, so to preserve state across open/close we run
# the shell inside a per-workspace detached session (dtach/abduco/tmux) and
# re-attach on every open. No multiplexer installed? Degrade to a plain login
# shell — still fully usable, just fresh each time it's reopened.
#
# NOTE: the starting directory arrives via $HERDR_FLOAX_CWD, not herdr's --cwd
# flag. In herdr 0.7.1, `plugin pane open --cwd <path>` makes the new plugin
# pane exit immediately (it vanishes), so we set the directory here instead.
set -u

shell="${SHELL:-/bin/sh}"
ws="${HERDR_WORKSPACE_ID:-default}"
state_dir="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"

cd "${HERDR_FLOAX_CWD:-$HOME}" 2>/dev/null || cd "$HOME" 2>/dev/null || true

# dtach: attach-or-create (-A); -z disables the suspend key.
if command -v dtach >/dev/null 2>&1; then
  exec dtach -A "$state_dir/floax-$ws.dtach" -z "$shell" -l
# abduco: -A attach-or-create a session named per workspace.
elif command -v abduco >/dev/null 2>&1; then
  exec abduco -A "floax-$ws" "$shell" -l
# tmux: per-workspace session in its own server. Mouse is enabled so the
# wheel drives tmux's own copy mode: the floax app forwards SGR mouse events
# when the embedded app reports mouse (it always runs full-screen, so the
# app's own scrollback paging can't see its history). The socket name is
# overridable so tests can avoid touching a real install's server.
elif command -v tmux >/dev/null 2>&1; then
  sock="${HERDR_FLOAX_TMUX_SOCKET:-herdr-floax}"
  tmux -L "$sock" new-session -d -s "$ws" "$shell -l" 2>/dev/null || true
  tmux -L "$sock" set-option -g mouse on 2>/dev/null || true
  exec tmux -L "$sock" attach-session -t "$ws"
fi

exec "$shell" -l
