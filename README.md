# herdr-floax

A floating scratch shell for the current [herdr](https://herdr.dev) workspace —
inspired by [`tmux-floax`](https://github.com/omerxx/tmux-floax). Maintained at
[`RooseveltAdvisors/herdr-floax`](https://github.com/RooseveltAdvisors/herdr-floax),
a fork of [`Tyru5/herdr-floax`](https://github.com/Tyru5/herdr-floax).

One keybinding toggles a floating pane: **open → reveal → dismiss**, one
instance per workspace. The floating pane is a **real herdr terminal** running
your login shell — not a nested TUI — so everything that works in a normal
pane works here, including **herdr copy mode and host scrollback**.

## How it works

Pressing the key toggles one floating pane per workspace:

- **no floating pane yet** → opens a zoomed split hosting your login shell
- **focused on it** → dismisses it (closes the pane; the shell session can
  survive — see [Persistence](#persistence))
- **exists but you focused away** → reveals + re-maximizes it

Under the hood the pane runs `scripts/floating-shell.sh` as a normal herdr
pane process on the **primary screen**. The toggle script opens a **split**
and immediately **zooms** it so the shell fills the workspace (herdr’s
`overlay`/`zoomed` placements are torn down when opened from a keybinding;
`popup` is sized but is not a tiled pane, so herdr copy mode does not target
it).

## Scrolling and copy mode

Because the shell is a first-class herdr pane on the primary screen:

| Action | Result |
|---|---|
| **herdr copy mode** (e.g. `prefix+j`) | Enters copy mode on floax history |
| **`C-u` / `C-d`** (in copy mode) | Half-page scroll through floax scrollback |
| **Mouse wheel** (no mouse reporting) | Herdr host-scrolls the pane scrollback |
| **Drag select** | Ordinary herdr selection on visible cells |
| **PgUp / PgDn** (live, not in copy mode) | Herdr host scrollback only while the shell is not in application-cursor mode — `zsh`/`bash` line editors usually claim these keys, so use copy mode |

This matches the tmux-floax idea that the floating shell is a **real pane**
with host-owned history — not an alternate-screen app herdr cannot scroll.

### Why 0.4.0 dropped the nested TUI

0.3.x drew a sized box with `ratatui` + an inner PTY on the alternate screen
and tried to own PgUp/wheel inside the plugin. That blocked herdr copy mode
(empty host scrollback on alt-screen) and fought mouse-reporting vs selection.
0.4.0 removes that nest so stock herdr 0.7.5 input paths work unchanged.

## Persistence

Dismiss **closes** the herdr pane. To keep the same shell across toggles,
install a raw PTY multiplexer that does **not** use the alternate screen:

- **`dtach`** (preferred) or **`abduco`** — reattach the same session on open
- **neither installed** — each open starts a fresh login shell
- **`HERDR_FLOAX_USE_TMUX=1`** — optional legacy: wrap in tmux instead, even
  when dtach/abduco are installed (inner tmux copy mode works; **herdr** copy
  mode will **not** see that history, because `tmux attach` uses the alternate
  screen). Set it in herdr's own environment — see [Configuration](#configuration)

## Limitations

**No app-drawn floating box / dimmed live backdrop.** The pane is a zoomed
split filling the workspace. tmux-floax can composite over live panes; a herdr
plugin only controls its own pane. Herdr 0.7.5’s `popup` placement is closer
visually but does not participate in tiled-pane copy mode (see comments in
`scripts/toggle-floating.sh`).

**Related herdr 0.7.x quirks this plugin works around:**

- `overlay`/`zoomed` vanish when opened from a keybinding — hence split-then-zoom
- `plugin pane open --cwd` could exit immediately on older builds — cwd travels
  via `HERDR_FLOAX_CWD`

## Configuration

Optional command profiles live in `~/.config/herdr/floax.conf`:

```toml
[profile.quota]
command = "while :; do quota-axi; sleep 60; done"
```

The command is shell syntax, runs inside the persistent primary-screen session,
and returns to the normal login shell when it exits. Each profile has its own
persistent session, so switching from the default shell to a profile starts
the configured command instead of reattaching the default session. A profile
is applied only on a fresh open; revealing an existing pane does not replace
its process.
`herdr-floax.toggle-cmd` uses the `quota` profile. The example uses a plain
text loop because `quota-axi --refresh` currently requires `--tui`, which would
put the command on the alternate screen and defeat floax copy mode.

`floax.conf.example` is a copyable example of this syntax.

Env:

| Variable | Meaning |
|---|---|
| `HERDR_FLOAX_CWD` | Starting directory (set by the toggle script) |
| `HERDR_FLOAX_USE_TMUX=1` | Opt into tmux-wrapped shell (breaks host copy mode); takes precedence over dtach/abduco |
| `HERDR_FLOAX_TMUX_SOCKET` | tmux socket name when tmux path is enabled |

The toggle action uses herdr's injected `HERDR_BIN_PATH` when it points to an
executable file. If that path is stale or unset, it resolves `herdr` from
`PATH`; if neither is available, it reports an error and exits with status
127.

The pane inherits **herdr's** environment, so the two tmux knobs must be set
where herdr itself starts (`HERDR_FLOAX_USE_TMUX=1 herdr …`, or your login
shell profile) — exporting them in a shell running *inside* herdr does not
reach the floating pane.

## Install

From GitHub:

```sh
herdr plugin install RooseveltAdvisors/herdr-floax

# Default keybind (prefix+f), then reload herdr config:
bash "$(herdr plugin list --plugin herdr-floax --json | jq -r '.result.plugins[0].plugin_root')/scripts/install-keybinding.sh"
```

Local development:

```sh
herdr plugin link /path/to/herdr-floax
bash /path/to/herdr-floax/scripts/install-keybinding.sh
```

Requires [`jq`](https://jqlang.github.io/jq/). No Rust toolchain required for
the 0.4.0 pane path. Optional: `dtach` or `abduco` for session persistence.

## Keybinding

Default **`prefix+f`**. Change it:

```sh
scripts/install-keybinding.sh prefix+g
# or
HERDR_FLOAX_KEY=prefix+g scripts/install-keybinding.sh
```

…or in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+f"
type = "plugin_action"
command = "herdr-floax.toggle"
description = "Toggle floating pane"
```

For the built-in quota profile:

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "herdr-floax.toggle-cmd"
description = "quota (floax)"
```

Reload herdr config after changing it.

## Files

| File | Purpose |
|---|---|
| `herdr-plugin.toml` | Manifest: `[[panes]]` (shell script) + toggle actions |
| `scripts/toggle-floating.sh` | open ↔ reveal ↔ dismiss, per workspace |
| `scripts/floating-shell.sh` | profile command, then login shell; dtach/abduco when available |
| `scripts/install-keybinding.sh` | default keybind installer |
| `floax.conf.example` | command-profile example |
| `src/` | legacy 0.3.x nested TUI (not used as the pane command) |
