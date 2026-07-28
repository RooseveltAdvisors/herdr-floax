#!/usr/bin/env bash
# Which process does the floax pane actually exec?
#
# The order matters for scrollback: dtach/abduco keep the pane on the primary
# screen (herdr copy mode sees history); the HERDR_FLOAX_USE_TMUX=1 opt-in is an
# explicit request for the alternate-screen path and must win over auto-detected
# multiplexers. Stubs on PATH stand in for the real binaries so the check runs
# on any box.
#
#   Usage: tests/floating-shell-precedence.sh [path/to/floating-shell.sh]
set -uo pipefail

script="${1:-$(dirname "$0")/../scripts/floating-shell.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"

for name in tmux dtach abduco; do
  printf '#!/bin/sh\necho "EXEC:%s"\n' "$name" > "$tmp/bin/$name"
  chmod +x "$tmp/bin/$name"
done
printf '#!/bin/sh\necho "EXEC:shell"\n' > "$tmp/bin/fakeshell"
chmod +x "$tmp/bin/fakeshell"

fails=0

# run <expected> <label> <available-stub>... -- <env assignment>...
run() {
  local expected="$1" label="$2"; shift 2
  local avail=() envs=()
  while [ "$1" != "--" ]; do avail+=("$1"); shift; done
  shift
  envs=("$@")

  local bin="$tmp/run"
  rm -rf "$bin"; mkdir -p "$bin"
  local n
  for n in "${avail[@]}"; do cp "$tmp/bin/$n" "$bin/$n"; done

  local out
  out="$(env -i HOME="$tmp/home" SHELL="$tmp/bin/fakeshell" \
        PATH="$bin:/usr/bin:/bin" "${envs[@]}" \
        bash "$script" 2>&1)"

  if printf '%s' "$out" | grep -q "EXEC:$expected"; then
    echo "ok   — $label → $expected"
  else
    echo "FAIL — $label: expected EXEC:$expected, got: ${out//$'\n'/ | }"
    fails=$((fails + 1))
  fi
}

# no opt-in: dtach is the preferred auto-detected primary-screen multiplexer
run dtach  "auto-detect prefers dtach"            tmux dtach abduco --
run abduco "auto-detect falls back to abduco"     tmux abduco       --
run shell  "no multiplexer → bare login shell"    tmux              --

# opt-in: an explicit tmux request beats auto-detected dtach/abduco
run tmux   "USE_TMUX=1 beats dtach"               tmux dtach abduco -- HERDR_FLOAX_USE_TMUX=1
run dtach  "USE_TMUX=1 without tmux falls back"        dtach abduco -- HERDR_FLOAX_USE_TMUX=1
run dtach  "USE_TMUX=0 leaves auto-detect alone"  tmux dtach        -- HERDR_FLOAX_USE_TMUX=0

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; fi
exit "$fails"
