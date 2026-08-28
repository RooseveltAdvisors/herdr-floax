#!/usr/bin/env bash
# Verify profile sessions do not reattach the default persistent shell.
set -uo pipefail

script="${1:-$(dirname "$0")/../scripts/floating-shell.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"

cat > "$tmp/bin/dtach" <<'EOF'
#!/usr/bin/env bash
socket="$2"
marker="$socket.active"
if [ -e "$marker" ]; then
  printf 'REATTACHED %s\n' "$socket"
else
  : > "$marker"
  printf 'STARTED %s\n' "$socket"
  printf 'COMMAND %s\n' "${*:4}"
  printf 'ENV_COMMAND %s\n' "${HERDR_FLOAX_COMMAND:-}"
fi
EOF
chmod +x "$tmp/bin/dtach"

run_shell() {
  env -i HOME="$tmp" SHELL=/bin/sh HERDR_WORKSPACE_ID=workspace \
    HERDR_PLUGIN_STATE_DIR="$tmp/state" HERDR_FLOAX_CWD="$tmp" \
    HERDR_FLOAX_SESSION="${HERDR_FLOAX_SESSION:-}" \
    HERDR_FLOAX_COMMAND="${HERDR_FLOAX_COMMAND:-}" \
    PATH="$tmp/bin:/usr/bin:/bin" "$script" "$@"
}

default_out="$(run_shell)"
profile_out="$(HERDR_FLOAX_SESSION=quota HERDR_FLOAX_COMMAND="quota-axi" run_shell)"

if [[ "$default_out" == STARTED*"floax-workspace-default.dtach"* ]] &&
   [[ "$profile_out" == STARTED*"floax-workspace-quota.dtach"* ]] &&
   [[ "$profile_out" == *"ENV_COMMAND quota-axi"* ]]; then
  echo "ok   - profile starts its own persistent session"
else
  echo "FAIL - profile reused the default persistent session"
  printf '%s\n%s\n' "$default_out" "$profile_out"
  exit 1
fi
