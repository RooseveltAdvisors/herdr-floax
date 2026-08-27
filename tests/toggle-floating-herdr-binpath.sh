#!/usr/bin/env bash
# Regression coverage for stale HERDR_BIN_PATH injection.
set -uo pipefail

script="${1:-$(dirname "$0")/../scripts/toggle-floating.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL - jq is required for the fallback behavior check"
  exit 1
fi

mkdir -p "$tmp/bin" "$tmp/no-herdr"
cat > "$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "pane list") printf '%s\n' '{"result":{"panes":[]}}' ;;
  "plugin pane") printf '%s\n' '{"result":{"plugin_pane":{"pane":{"pane_id":"opened"}}}}' ;;
  *) printf '%s\n' '{"result":{"pane":{"workspace_id":"test","pane_id":"source","cwd":"/tmp"}}}' ;;
esac
EOF
chmod +x "$tmp/bin/herdr"
: > "$tmp/stale-herdr"

cp "$tmp/bin/herdr" "$tmp/path-herdr"
chmod +x "$tmp/path-herdr"
if HERDR_BIN_PATH="$tmp/path-herdr" HERDR_WORKSPACE_ID=test HERDR_PANE_ID=source \
    HERDR_LOG="$tmp/path.log" PATH="$tmp/bin:/usr/bin:/bin" \
    /usr/bin/bash "$script" >"$tmp/path.out" 2>&1; then
  if grep -Fq 'path-herdr pane list' "$tmp/path.log"; then
    echo "ok   - executable HERDR_BIN_PATH is preferred"
  else
    echo "FAIL - executable HERDR_BIN_PATH was not preferred"
    fails=$((fails + 1))
  fi
else
  echo "FAIL - executable HERDR_BIN_PATH exited non-zero: $(<"$tmp/path.out")"
  fails=$((fails + 1))
fi

if HERDR_BIN_PATH="$tmp/stale-herdr" HERDR_WORKSPACE_ID=test HERDR_PANE_ID=source \
    HERDR_LOG="$tmp/fallback.log" PATH="$tmp/bin:/usr/bin:/bin" \
    /usr/bin/bash "$script" >"$tmp/fallback.out" 2>&1; then
  if grep -Fq 'pane list' "$tmp/fallback.log"; then
    echo "ok   - stale HERDR_BIN_PATH falls back to PATH herdr"
  else
    echo "FAIL - fallback herdr was not invoked"
    fails=$((fails + 1))
  fi
else
  echo "FAIL - stale HERDR_BIN_PATH fallback exited non-zero: $(<"$tmp/fallback.out")"
  fails=$((fails + 1))
fi

jq_dir="$(dirname "$(command -v jq)")"
if HERDR_BIN_PATH="$tmp/stale-herdr" PATH="$tmp/no-herdr:$jq_dir" \
    /usr/bin/bash "$script" >"$tmp/missing.out" 2>&1; then
  echo "FAIL - missing herdr unexpectedly succeeded"
  fails=$((fails + 1))
else
  status=$?
  if [ "$status" -eq 127 ] && grep -Fq 'no executable herdr binary found' "$tmp/missing.out"; then
    echo "ok   - missing herdr reports an error and exits 127"
  else
    echo "FAIL - missing herdr returned $status: $(<"$tmp/missing.out")"
    fails=$((fails + 1))
  fi
fi

exit "$fails"
