#!/usr/bin/env bash
# The floating pane's process: a normal interactive login shell on the herdr
# pane's primary screen.
#
# Why not a nested TUI / tmux attach by default?
#   herdr copy mode and host scrollback only see the pane's primary screen.
#   A nested ratatui box or `tmux attach` switches the pane to the alternate
#   screen, so prefix+j / C-u / C-d have nothing to scroll. Running the shell
#   (or a raw PTY multiplexer) directly keeps history in herdr.
#
# Persistence across toggle dismiss (which closes the herdr pane):
#   dtach or abduco reattach the same PTY without using the alternate screen.
#   plain shell if neither is installed (fresh session each open).
#
# Optional legacy path:
#   HERDR_FLOAX_USE_TMUX=1 falls back to a per-workspace tmux session (alt
#   screen). That restores tmux-style inner copy mode but breaks herdr host
#   copy mode / scrollback — only for users who explicitly want it.
#
# Starting directory arrives via $HERDR_FLOAX_CWD (not herdr --cwd): in herdr
# 0.7.1, `plugin pane open --cwd` made the pane exit immediately.
set -u

shell="${SHELL:-/bin/sh}"
ws="${HERDR_WORKSPACE_ID:-default}"
state_dir="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"

cd "${HERDR_FLOAX_CWD:-$HOME}" 2>/dev/null || cd "$HOME" 2>/dev/null || true

# dtach: attach-or-create (-A); -z disables the suspend key. Raw PTY — primary
# screen, herdr keeps scrollback.
if command -v dtach >/dev/null 2>&1; then
  exec dtach -A "$state_dir/floax-$ws.dtach" -z "$shell" -l
fi

# abduco: -A attach-or-create a session named per workspace.
if command -v abduco >/dev/null 2>&1; then
  exec abduco -A "floax-$ws" "$shell" -l
fi

# Opt-in tmux path (alternate screen — herdr copy mode will not see history).
if [ "${HERDR_FLOAX_USE_TMUX:-}" = "1" ] && command -v tmux >/dev/null 2>&1; then
  sock="${HERDR_FLOAX_TMUX_SOCKET:-herdr-floax}"
  tmux -L "$sock" new-session -d -s "$ws" "$shell -l" 2>/dev/null || true
  tmux -L "$sock" set-option -g mouse on 2>/dev/null || true
  exec tmux -L "$sock" attach-session -t "$ws"
fi

exec "$shell" -l
