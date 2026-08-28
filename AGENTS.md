# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Notes

- **Project shape:** herdr-floax is a herdr plugin providing one floating
  scratch shell per workspace; the current 0.4.0 path is shell scripts, not the
  retained 0.3.x Rust TUI. The manifest and README are authoritative for the
  plugin surface.
- **Architecture (0.4.0+):** the pane command is `bash scripts/floating-shell.sh` — a real herdr primary-screen shell (split + zoom via `scripts/toggle-floating.sh`). No nested ratatui/vt100 TUI. Host scrollback + herdr copy mode (`prefix+j`, `C-u`/`C-d`) work because the shell is not on the alternate screen.
- **Toggle contract:** `scripts/toggle-floating.sh` is workspace-scoped
  launch-or-reveal/dismiss: absent opens, unfocused reveals and re-zooms,
  focused closes. Keep the split-then-`pane zoom --on` sequence; keybinding
  actions tear down `overlay`/`zoomed` placements. It saves a pre-existing
  workspace zoom under `HERDR_PLUGIN_STATE_DIR` and restores it on dismiss.
- **Why not herdr `popup` placement:** stock 0.7.5 popup is session-modal outside the tiled layout; `enter_copy_mode` targets the focused *tiled* pane, and while a popup is open all keys are forwarded into it (prefix never enters copy mode on popup history). Split+zoom is the copy-mode-compatible floating shape.
- **Why not default `tmux attach`:** tmux clients use the alternate screen, so herdr’s primary-screen scrollback/copy-mode stay empty. Persistence without alt-screen: `dtach` or `abduco`. `HERDR_FLOAX_USE_TMUX=1` opts back into tmux (inner copy mode only).
- **Injected binary invariant (stale-binary fix):** every consumer of `HERDR_BIN_PATH`
  must accept it only when it is a regular executable file (`-f` and `-x`),
  otherwise fall back to `command -v herdr`; report no executable and exit 127
  if neither works. Regression coverage lives in
  `tests/toggle-floating-herdr-binpath.sh`.
- **herdr scrolling contract (0.7.5):** scrollback from primary screen only; `wheel_routing` = MouseReport | AlternateScroll | HostScroll; plain PgUp/PgDn stolen by host only on primary + no mouse + no app cursor.
- **Canonical checks:** `.github/workflows/ci.yml` runs
  `shellcheck scripts/*.sh`, `bash -n scripts/*.sh`, and the missing-`jq` smoke
  check. Run the two regression scripts directly before changing shell behavior:
  `bash tests/floating-shell-precedence.sh` and
  `bash tests/toggle-floating-herdr-binpath.sh`.
- **Legacy nested TUI:** `src/` + `Cargo.toml` remain from 0.3.x but are not the pane command and are not built at plugin install. Prefer deleting in a follow-up once 0.4.0 is confirmed.
- **Lab isolation:** never test against a live herdr/default session. Run a second herdr with scrubbed env (`env -i HOME=… XDG_CONFIG_HOME=<tmp> XDG_STATE_HOME=<tmp>`, no `HERDR_*`) inside its own tmux session, `herdr plugin link <worktree>` against it, and set `HERDR_FLOAX_TMUX_SOCKET` to a throwaway name so the tmux opt-in can never attach the real `herdr-floax` socket. Drive it with `herdr pane send-text` / `tmux send-keys`. After manifest changes, re-link or reload so herdr picks up the new command.
- **No cargo required** for the 0.4.0 pane path. Shellcheck the scripts; the live-path check is `tests/floating-shell-precedence.sh` (stubs tmux/dtach/abduco on `PATH` and asserts which one `floating-shell.sh` execs).

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
