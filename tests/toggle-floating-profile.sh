#!/usr/bin/env bash
# Observable profile parsing and HERDR_FLOAX_COMMAND pass-through check.
set -uo pipefail

script="${1:-$(dirname "$0")/../scripts/toggle-floating.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/.config/herdr"
cat > "$tmp/home/.config/herdr/floax.conf" <<'EOF'
[profile.other]
command = "other-command"

[profile.quota]
command = "printf '# ready'"

[profile.quota-plain]
command = "plain-command"
EOF
cat > "$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf 'CALL' >> "$HERDR_LOG"
printf ' <%s>' "$@"
printf ' <%s>' "$@" >> "$HERDR_LOG"
printf '\n' >> "$HERDR_LOG"
case "$1 $2" in
  "pane list") printf '%s\n' '{"result":{"panes":[]}}' ;;
  "pane get") printf '%s\n' '{"result":{"pane":{"cwd":"/tmp"}}}' ;;
  "plugin pane") printf '%s\n' '{"result":{"plugin_pane":{"pane":{"pane_id":"opened"}}}}' ;;
  *) printf '%s\n' '{"result":{"pane":{"workspace_id":"test","pane_id":"source","cwd":"/tmp"}}}' ;;
esac
EOF
chmod +x "$tmp/bin/herdr"

jq_dir="$(dirname "$(command -v jq)")"
log="$tmp/herdr.log"
if HOME="$tmp/home" HERDR_WORKSPACE_ID=test HERDR_PANE_ID=source \
    HERDR_LOG="$log" PATH="$tmp/bin:$jq_dir:/usr/bin:/bin" \
    /usr/bin/bash "$script" quota >"$tmp/out" 2>&1; then
  if grep -Fq -- "<--env> <HERDR_FLOAX_COMMAND=printf '# ready'>" "$log"; then
    if grep -Fq -- "<--env> <HERDR_FLOAX_SESSION=quota>" "$log"; then
      echo "ok   - selected profile command reaches fresh pane open"
    else
      echo "FAIL - selected profile session identity was not passed to pane open"
      cat "$log"
      exit 1
    fi
  else
    echo "FAIL - selected profile command was not passed to pane open"
    cat "$log"
    exit 1
  fi
else
  echo "FAIL - profile open failed: $(<"$tmp/out")"
  exit 1
fi

: > "$log"
if HOME="$tmp/home" HERDR_WORKSPACE_ID=test HERDR_PANE_ID=source \
    HERDR_LOG="$log" PATH="$tmp/bin:$jq_dir:/usr/bin:/bin" \
    /usr/bin/bash "$script" quota-plain >"$tmp/out" 2>&1; then
  if grep -Fq -- "<--env> <HERDR_FLOAX_COMMAND=plain-command>" "$log" &&
     grep -Fq -- "<--env> <HERDR_FLOAX_SESSION=quota-plain>" "$log"; then
    echo "ok   - plain profile command and session reach fresh pane open"
  else
    echo "FAIL - plain profile was not passed to pane open"
    cat "$log"
    exit 1
  fi
else
  echo "FAIL - plain profile open failed: $(<"$tmp/out")"
  exit 1
fi
