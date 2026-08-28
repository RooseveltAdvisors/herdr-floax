#!/usr/bin/env bash
# Verify profile actions in the machine-consumed plugin manifest.
set -euo pipefail

manifest="${1:-$(dirname "$0")/../herdr-plugin.toml}"

python3 - "$manifest" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as manifest_file:
    manifest = tomllib.load(manifest_file)

actions = {action["id"]: action for action in manifest.get("actions", [])}
for action_id, profile in (("toggle-cmd", "quota"), ("toggle-plain", "quota-plain")):
    action = actions.get(action_id)
    expected = ["bash", "scripts/toggle-floating.sh", profile]
    if action is None or action.get("command") != expected:
        raise SystemExit(
            f"{action_id}: expected command {expected!r}, got "
            f"{None if action is None else action.get('command')!r}"
        )

print("ok   - quota and quota-plain actions are registered")
PY
