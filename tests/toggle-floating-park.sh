#!/usr/bin/env bash
# Verify the park/restore contract: DISMISS parks the pane with `pane move`
# (the shell keeps running), and the next toggle moves the same pane back
# instead of opening a fresh one.
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
    if [ "$count" = "0" ]; then
      # Before parking: floax is present and focused (dismiss run), or absent
      # (open run, MODE=open). After parking: absent.
      case "$MODE" in
        open) printf '%s\n' '{"result":{"panes":[{"pane_id":"source","focused":true}]}}' ;;
        restore) printf '%s\n' '{"result":{"panes":[{"pane_id":"source","focused":true}]}}' ;;
        stale) printf '%s\n' '{"result":{"panes":[{"pane_id":"source","focused":true}]}}' ;;
        *) printf '%s\n' '{"result":{"panes":[{"label":"⌂ floax","focused":true,"pane_id":"float"}]}}' ;;
      esac
    else
      printf '%s\n' '{"result":{"panes":[{"pane_id":"source","focused":true}]}}'
    fi
    ;;
  "pane get")
    if [ "$3" = "parked" ]; then
      # Live parked pane (restore/stale decides) plus tab/cwd lookups.
      if [ "$MODE" = "stale" ]; then
        printf '%s\n' '{"error":{"code":"pane_not_found"}}'
        exit 1
      else
        printf '%s\n' '{"result":{"pane":{"pane_id":"parked","tab_id":"parktab"}}}'
      fi
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"'"$3"'","tab_id":"test:t1","cwd":"/tmp"}}}'
    fi
    ;;
  "pane zoom")
    printf 'ZOOM %s %s\n' "$3" "$4" >> "$HERDR_LOG"
    ;;
  "pane move")
    printf 'MOVE %s\n' "$*" >> "$HERDR_LOG"
    case "$*" in
      *--new-workspace*)
        printf '%s\n' '{"result":{"move_result":{"changed":true,"pane":{"pane_id":"parked"}}}}'
        ;;
      pane*)
        printf '%s\n' '{"result":{"move_result":{"changed":true,"pane":{"pane_id":"float"}}}}'
        ;;
      *)
        printf '%s\n' '{"result":{"move_result":{"changed":true,"pane":{"pane_id":"float"}}}}'
        ;;
    esac
    ;;
  "plugin pane")
    printf 'OPEN %s\n' "$*" >> "$HERDR_LOG"
    printf '%s\n' '{"result":{"plugin_pane":{"pane":{"pane_id":"float"}}}}'
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

run_toggle() {
  MODE="$1" HERDR_BIN_PATH="$tmp/bin/herdr" HERDR_COUNT="$count" HERDR_LOG="$log" \
    HOME="$tmp/home" HERDR_WORKSPACE_ID=test HERDR_PANE_ID=source HERDR_TAB_ID=test:t1 \
    HERDR_PLUGIN_STATE_DIR="$tmp/state" PATH="$tmp/bin:$jq_dir:/usr/bin:/bin" \
    /usr/bin/bash "$script"
}

# 1. DISMISS parks the pane and records the new (workspace-qualified) id.
printf '0\n' > "$count"
run_toggle dismiss || { echo "FAIL - dismiss errored: $(<"$log")"; exit 1; }
if [ ! -f "$tmp/state/floax-parked-test-default" ] ||
    [ "$(<"$tmp/state/floax-parked-test-default")" != "parked" ]; then
  echo "FAIL - dismiss did not record the parked pane id"
  printf '%s\n' "$(<"$log")"
  exit 1
fi
if ! grep -q -- "--new-workspace" "$log"; then
  echo "FAIL - dismiss did not park via pane move --new-workspace"
  printf '%s\n' "$(<"$log")"
  exit 1
fi
if grep -q "CLOSE" "$log"; then
  echo "FAIL - dismiss closed the pane instead of parking it"
  printf '%s\n' "$(<"$log")"
  exit 1
fi

# 2. Next toggle restores the parked pane instead of opening a fresh one.
: > "$log"
printf '0\n' > "$count"
run_toggle restore || { echo "FAIL - restore errored: $(<"$log")"; exit 1; }
if grep -q "OPEN" "$log"; then
  echo "FAIL - restore opened a fresh pane instead of the parked one"
  printf '%s\n' "$(<"$log")"
  exit 1
fi
if ! grep -q "MOVE pane move parked --tab test:t1 --split right --target-pane source --focus" "$log"; then
  echo "FAIL - restore did not move the parked pane back into the invoking tab"
  printf '%s\n' "$(<"$log")"
  exit 1
fi
if ! grep -q "ZOOM float --on" "$log"; then
  echo "FAIL - restore did not re-maximize the restored pane"
  printf '%s\n' "$(<"$log")"
  exit 1
fi
if [ -e "$tmp/state/floax-parked-test-default" ]; then
  echo "FAIL - restore left a stale parked state behind"
  exit 1
fi

# 3. Stale parked state (pane gone) falls back to a fresh OPEN.
: > "$log"
printf '0\n' > "$count"
printf 'parked\n' > "$tmp/state/floax-parked-test-default"
run_toggle stale || { echo "FAIL - stale restore errored: $(<"$log")"; exit 1; }
if ! grep -q "OPEN" "$log"; then
  echo "FAIL - stale parked pane did not fall back to a fresh open"
  printf '%s\n' "$(<"$log")"
  exit 1
fi
if [ -e "$tmp/state/floax-parked-test-default" ]; then
  echo "FAIL - stale parked state was not cleared"
  exit 1
fi

echo "ok   - dismiss parks the pane and the next toggle restores it"
