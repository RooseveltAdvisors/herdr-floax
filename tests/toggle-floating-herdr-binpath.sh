#!/usr/bin/env bash
# Regression coverage for stale HERDR_BIN_PATH injection.
set -uo pipefail

script="${1:-$(dirname "$0")/../scripts/toggle-floating.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

assert_contains() {
  local pattern="$1"
  if grep -Fq -- "$pattern" "$script"; then
    echo "ok   — found: $pattern"
  else
    echo "FAIL — missing: $pattern"
    fails=$((fails + 1))
  fi
}

assert_contains "[ -x \"\$HERDR_BIN_PATH\" ]"
assert_contains 'command -v herdr'
assert_contains 'exit 127'

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL — jq is required for the fallback behavior check"
  exit 1
fi

mkdir -p "$tmp/bin" "$tmp/no-herdr"
cat > "$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "pane list") printf '%s\n' '{"result":{"panes":[]}}' ;;
  "plugin pane") printf '%s\n' '{"result":{"plugin_pane":{"pane":{"pane_id":"opened"}}}}' ;;
  *) printf '%s\n' '{"result":{"pane":{"workspace_id":"test","pane_id":"source","cwd":"/tmp"}}}' ;;
esac
EOF
chmod +x "$tmp/bin/herdr"
: > "$tmp/stale-herdr"

if HERDR_BIN_PATH="$tmp/stale-herdr" HERDR_WORKSPACE_ID=test HERDR_PANE_ID=source \
    HERDR_LOG="$tmp/fallback.log" PATH="$tmp/bin:/usr/bin:/bin" \
    /usr/bin/bash "$script" >"$tmp/fallback.out" 2>&1; then
  if grep -Fq 'pane list' "$tmp/fallback.log"; then
    echo "ok   — stale HERDR_BIN_PATH falls back to PATH herdr"
  else
    echo "FAIL — fallback herdr was not invoked"
    fails=$((fails + 1))
  fi
else
  echo "FAIL — stale HERDR_BIN_PATH fallback exited non-zero: $(cat "$tmp/fallback.out")"
  fails=$((fails + 1))
fi

if HERDR_BIN_PATH="$tmp/stale-herdr" PATH="$tmp/no-herdr" \
    /usr/bin/bash "$script" >"$tmp/missing.out" 2>&1; then
  echo "FAIL — missing herdr unexpectedly succeeded"
  fails=$((fails + 1))
else
  status=$?
  if [ "$status" -eq 127 ] && grep -Fq 'no executable herdr binary found' "$tmp/missing.out"; then
    echo "ok   — missing herdr reports an error and exits 127"
  else
    echo "FAIL — missing herdr returned $status: $(cat "$tmp/missing.out")"
    fails=$((fails + 1))
  fi
fi

exit "$fails"
