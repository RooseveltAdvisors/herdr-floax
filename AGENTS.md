# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Notes

- Build/test: `cargo build --release && cargo test` (unit tests live in `src/*.rs` modules). `cargo clippy --release` is kept clean.
- herdr scrolling contract (verified against herdr 0.7.5 source, `src/pane/terminal.rs` `wheel_routing` + `plain_page_keys_use_host_scrollback`): herdr captures scrollback only from a pane's **primary screen**, so herdr copy mode can never scroll an alternate-screen app like this plugin — plugin-owned scrolling (`src/input.rs`) is the fix, not a workaround. Wheel routing: mouse-reporting pane → SGR events to the pane; else alt-screen → Up/Down arrow keys (alternate scroll); else herdr scrolls its own scrollback. Plain PgUp/PgDn are intercepted by herdr only on primary-screen panes, so they always reach this app.
- Dependency pin worth knowing before touching scrolling or `Cargo.toml`: `vt100 = "0.15"` underflows in `Grid::visible_rows` whenever the scroll view is more than one screen back, which normal PgUp/wheel use reaches immediately; the wrapped result is what renders deep scrollback correctly, so `Cargo.toml` disables overflow checks **for the vt100 package only** rather than clamping the offset (clamping would cap scrolling at one page). Upstream fixed it in vt100 0.16, which needs `unicode-width >= 0.2.1` while ratatui 0.29 pins `=0.2.0` — so taking the fix means bumping ratatui first, and the override can go away then.
- The plugin pane command is `./target/release/herdr-floax` — after code changes, dismiss and reopen the floax pane to pick up a rebuild.
- Testing end-to-end without touching a live herdr: run a second herdr with scrubbed env (`env -i HOME=... XDG_CONFIG_HOME=<tmp> XDG_STATE_HOME=<tmp>`, no `HERDR_*`) inside tmux, `herdr plugin link <worktree>` against it, and set `HERDR_FLOAX_TMUX_SOCKET` so `scripts/floating-shell.sh` never attaches to the real `herdr-floax` tmux socket. Drive it with `tmux send-keys`; inject SGR mouse events with `herdr pane send-text`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
