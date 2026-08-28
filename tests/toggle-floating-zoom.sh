#!/usr/bin/env bash
# Verify that floax restores the pane that was zoomed before it opened.
set -uo pipefail

script="${1:-$(dirname "$0")/../scripts/toggle-floating.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state" "$tmp/home"

cat > "$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "pane list")
    count="$(cat "$HERDR_COUNT")"
    printf '%s\n' "$((count + 1))" > "$HERDR_COUNT"
    case "$MODE:$count" in
      open:*)
        printf '%s\n' '{"result":{"panes":[{"pane_id":"source","focused":true}]}}'
        ;;
      reveal:0)
        printf '%s\n' '{"result":{"panes":[{"label":"⌂ floax","focused":false,"pane_id":"float"}]}}'
        ;;
      dismiss:0|fail:0|restore-fail:0)
        printf '%s\n' '{"result":{"panes":[{"label":"⌂ floax","focused":true,"pane_id":"float"}]}}'
        ;;
      restore-fail:*)
        printf '%s\n' 'not-json'
        ;;
      dismiss:*)
        printf '%s\n' '{"result":{"panes":[{"pane_id":"source","focused":true}]}}'
        ;;
    esac
    ;;
  "pane layout")
    printf '%s\n' '{"result":{"layout":{"zoomed":true,"focused_pane_id":"source"}}}'
    ;;
  "pane get")
    printf '%s\n' '{"result":{"pane":{"cwd":"/tmp"}}}'
    ;;
  "pane zoom")
    printf 'ZOOM %s %s\n' "$3" "$4" >> "$HERDR_LOG"
    ;;
  "plugin pane")
    if [ "$3" = "open" ]; then
      printf '%s\n' '{"result":{"plugin_pane":{"pane":{"pane_id":"float"}}}}'
    else
      printf 'CLOSE %s\n' "$4" >> "$HERDR_LOG"
      [ "$MODE" != "fail" ]
    fi
    ;;
  *)
    printf '%s\n' '{"result":{"pane":{"workspace_id":"test","pane_id":"source","cwd":"/tmp"}}}'
    ;;
esac
EOF
chmod +x "$tmp/bin/herdr"

jq_dir="$(dirname "$(command -v jq)")"
log="$tmp/herdr.log"
count="$tmp/count"
printf '0\n' > "$count"

run_toggle() {
  printf '0\n' > "$count"
  MODE="$1" HERDR_BIN_PATH="$tmp/bin/herdr" HERDR_COUNT="$count" HERDR_LOG="$log" \
    HOME="$tmp/home" HERDR_WORKSPACE_ID=test HERDR_PANE_ID=source \
    HERDR_PLUGIN_STATE_DIR="$tmp/state" PATH="$tmp/bin:$jq_dir:/usr/bin:/bin" \
    /usr/bin/bash "$script"
}

run_toggle open
if [ "$(<"$tmp/state/floax-zoom-test")" != "source" ]; then
  echo "FAIL - opening floax did not save the existing zoom"
  exit 1
fi

run_toggle reveal
if [ "$(<"$tmp/state/floax-zoom-test")" != "source" ]; then
  echo "FAIL - revealing floax replaced the saved zoom"
  exit 1
fi

if run_toggle fail; then
  echo "FAIL - simulated close failure unexpectedly succeeded"
  exit 1
fi
if [ "$(<"$tmp/state/floax-zoom-test")" != "source" ]; then
  echo "FAIL - failed close discarded the saved zoom"
  exit 1
fi

if run_toggle restore-fail; then
  echo "FAIL - simulated restore failure unexpectedly succeeded"
  exit 1
fi
if [ "$(<"$tmp/state/floax-zoom-test")" != "source" ]; then
  echo "FAIL - failed restore discarded the saved zoom"
  exit 1
fi

run_toggle dismiss
if [ -e "$tmp/state/floax-zoom-test" ]; then
  echo "FAIL - dismiss did not clear the saved zoom"
  printf '%s\n' "$(<"$log")"
  exit 1
fi

log_contents="$(<"$log")"
if [[ "$log_contents" == *"CLOSE float"* &&
      "$log_contents" == *"pane layout --pane source"* &&
      "$log_contents" == *"ZOOM source --on"* ]]; then
  echo "ok   - dismiss restores the pre-floax zoom"
else
  echo "FAIL - dismiss did not close floax and restore source zoom"
  printf '%s\n' "$log_contents"
  exit 1
fi
