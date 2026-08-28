#!/usr/bin/env bash
# Verify the command-profile action in the machine-consumed manifest.
set -euo pipefail

manifest="${1:-$(dirname "$0")/../herdr-plugin.toml}"

python3 - "$manifest" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as manifest_file:
    manifest = tomllib.load(manifest_file)

actions = {action["id"]: action for action in manifest.get("actions", [])}
action = actions.get("toggle-cmd")
expected = ["bash", "scripts/toggle-floating.sh", "quota"]
if action is None or action.get("command") != expected:
    raise SystemExit(
        f"toggle-cmd: expected command {expected!r}, got "
        f"{None if action is None else action.get('command')!r}"
    )

print("ok   - quota action is registered")
PY
