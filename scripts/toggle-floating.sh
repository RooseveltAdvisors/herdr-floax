#!/usr/bin/env bash
# Toggle the floating scratch pane for the CURRENT workspace.
#
# "Launch-or-reveal, dismiss on repeat", scoped per workspace. The floating
# pane is a real herdr split running scripts/floating-shell.sh; we zoom it for
# a full-workspace floating look. Found by its label ("⌂ floax") within this
# workspace:
#
#   - no floating pane in this workspace       -> OPEN a new one, maximized
#   - a floating pane exists but isn't focused  -> REVEAL it (focus + maximize)
#   - the floating pane IS the focused pane      -> DISMISS it (close)
#
# herdr injects $HERDR_WORKSPACE_ID / $HERDR_PANE_ID / $HERDR_BIN_PATH into this
# action command. Any parse/edge failure degrades to OPEN — never a silent
# no-op. Persistence across a DISMISS is provided by scripts/floating-shell.sh
# (dtach/abduco when installed).
set -uo pipefail

LABEL="⌂ floax"
if [ -n "${HERDR_BIN_PATH:-}" ] && [ -x "$HERDR_BIN_PATH" ]; then
  herdr="$HERDR_BIN_PATH"
else
  herdr="$(command -v herdr || true)"
fi

if [ -z "$herdr" ]; then
  echo "herdr-floax: no executable herdr binary found (HERDR_BIN_PATH is stale or unset)" >&2
  exit 127
fi

# jq is required to parse the pane-list JSON. Fail loudly with a fix hint.
if ! command -v jq >/dev/null 2>&1; then
  "$herdr" notification show "herdr-floax needs 'jq' installed" >/dev/null 2>&1 || \
    echo "herdr-floax: 'jq' is required (brew install jq / apt install jq)" >&2
  exit 1
fi

# Which workspace are we in? Prefer the injected env; fall back to pane.current.
ws="${HERDR_WORKSPACE_ID:-}"
if [ -z "$ws" ]; then
  ws="$("$herdr" pane current 2>/dev/null | jq -r '.result.pane.workspace_id // empty')"
fi

open_pane() {
  # Which pane are we launching from? Needed as the split's target and to
  # inherit its cwd. Prefer the injected id; fall back to the focused pane.
  local target="${HERDR_PANE_ID:-}"
  [ -z "$target" ] && target="$("$herdr" pane current 2>/dev/null | jq -r '.result.pane.pane_id // empty')"

  local cwd=""
  if [ -n "$target" ]; then
    cwd="$("$herdr" pane get "$target" 2>/dev/null | jq -r '.result.pane.cwd // empty')"
  fi
  [ -z "$cwd" ] && cwd="$("$herdr" pane current 2>/dev/null | jq -r '.result.pane.cwd // empty')"

  # `split`, then zoom — NOT `overlay`/`zoomed` (transient from keybindings)
  # and NOT `popup` (session-modal terminal outside the tiled layout: herdr
  # copy mode targets the focused tiled pane, not the popup, so prefix+j /
  # C-u/C-d would not scroll floax history).
  #
  # Starting directory via --env HERDR_FLOAX_CWD, not --cwd (herdr 0.7.1
  # quirk: --cwd could make the pane exit immediately).
  set -- plugin pane open --plugin herdr-floax --entrypoint floating \
      --placement split --direction right --env HERDR_FLOAX=1 --focus
  [ -n "$target" ] && set -- "$@" --target-pane "$target"
  [ -n "$cwd" ] && set -- "$@" --env "HERDR_FLOAX_CWD=$cwd"
  local out pid
  out="$("$herdr" "$@" 2>/dev/null)"
  pid="$(printf '%s' "$out" | jq -r '.result.plugin_pane.pane.pane_id // empty')"
  [ -n "$pid" ] && "$herdr" pane zoom "$pid" --on >/dev/null 2>&1
  exit 0
}

# Find our floating pane in this workspace: "<focused> <pane_id>", or empty.
found=""
if [ -n "$ws" ]; then
  found="$("$herdr" pane list --workspace "$ws" 2>/dev/null \
    | jq -r --arg L "$LABEL" '
        .result.panes[]? | select(.label == $L)
        | "\(.focused) \(.pane_id)"' 2>/dev/null | head -n1)"
fi

# No floating pane here → open one.
[ -z "$found" ] && open_pane

focused="${found%% *}"
pid="${found#* }"

if [ "$focused" = "true" ]; then
  # Currently shown (focused + maximized) → dismiss. floating-shell.sh keeps
  # the session alive when dtach/abduco is available.
  exec "$herdr" plugin pane close "$pid"
else
  # Exists but you focused away (so it un-maximized) → reveal.
  exec "$herdr" pane zoom "$pid" --on
fi
