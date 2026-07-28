# herdr-floax

A floating scratch shell for the current [herdr](https://herdr.dev) workspace —
inspired by [`tmux-floax`](https://github.com/omerxx/tmux-floax).

One keybinding toggles a floating pane: **open → reveal → dismiss**, one
instance per workspace. The floating pane is a real, fully-interactive herdr
pane (your login shell) — you can do anything in it that you can in a normal
pane. Its session persists across toggles.

## How it works

Pressing the key toggles one floating pane per workspace:

- **no floating pane yet** → opens a centered, sized popup (default 98%×96% —
  generous, since the backdrop is dead space; see
  [Limitations](#limitations)) hosting your login shell, over a dimmed backdrop
- **focused on it** → dismisses it (closes the pane; the shell session survives)
- **exists but you focused away** → reveals + re-maximizes it

Under the hood the pane runs a small Rust TUI (`ratatui` + `portable-pty` +
`vt100`) that draws the floating box and embeds a real shell PTY inside it —
the same way herdr-file-viewer draws its help overlay, except the box hosts a
live terminal instead of static text. Everything you can do in a normal pane
works in the box: vim, REPLs, paste, colors, resize. Input is byte-level
passthrough (only PgUp/PgDn and the wheel are intercepted, for scrolling —
see [Scrolling](#scrolling)), so no key handling is lost in translation.

The host pane itself is a herdr **split** that the toggle script immediately
zooms, so the box appears centered over the whole workspace. herdr's
`overlay`/`zoomed` placements can't be used from a keybinding — herdr tears
those transient views down the instant the invoking action finishes — and the
app-drawn box is what restores floax's sized-popup look on top of that
constraint.

## Scrolling

**herdr's copy mode cannot scroll the floax shell's history.** The app draws
on its pane's alternate screen, and herdr captures scrollback only from a
pane's primary screen — so in herdr copy mode the floax pane has no history
to page through (the same thing happens in tmux copy mode on a full-screen
app). Worse, herdr's default wheel behavior for alternate-screen panes is
"alternate scroll": it turns the wheel into Up/Down arrow keys, which landed
in the shell as history navigation.

So floax owns scrolling itself, the way tmux-floax owns it through tmux:

- **Plain shell in the box** (no multiplexer wrapper, or dtach/abduco):
  - **PgUp / PgDn** page through the embedded terminal's scrollback
    (herdr only steals plain PgUp/PgDn for its own scrollback on
    primary-screen panes, so they always reach floax here). The border shows
    `scrolled N` while you're back; typing snaps to the live prompt.
  - **Mouse wheel** scrolls 3 lines per notch. The app enables mouse
    reporting on its own pane, which flips herdr's wheel routing from
    alternate-scroll arrows to delivering real wheel events.
- **tmux-wrapped shell** (the default when `tmux` is installed): the inner
  tmux session owns history, exactly like tmux-floax. floax enables `mouse
  on` for that session and forwards mouse events to it, so the **wheel
  enters and scrolls tmux's copy mode**; `C-b [` + `q` works too.
- **Full-screen apps inside the box** (vim, less): PgUp/PgDn and the wheel
  are forwarded to the app (wheel becomes arrow keys when the app didn't
  enable mouse reporting — standard xterm alternate-scroll behavior).

Scrollback size is configurable (`scrollback_lines`, default 10,000 rows).
One trade-off to know: because the pane now reports mouse, click-drag
selection over the floax box goes to the embedded app instead of herdr's own
selection — use herdr copy mode (visible screen) or the wheel/tmux copy mode
for older text.

- **Scope:** per workspace. Toggling in workspace A and workspace B gives you two
  independent floating shells.
- **Persistence:** dismiss *closes* the pane, so the embedded shell runs inside a
  per-workspace detached session when a multiplexer (`dtach`, `abduco`, or
  `tmux`) is on your `PATH` — anything running in it survives dismiss/reopen.
  Without one, it degrades to a plain login shell (fresh each reopen).
- **Backdrop:** see [Limitations](#limitations) — the area around the box uses
  your terminal background, not your live panes dimmed behind it.

## Limitations

**The backdrop is not your real workspace.** In tmux-floax, the popup floats
over your *live* session — you see your actual panes, dimmed, behind the box.
herdr-floax cannot replicate that: the plugin only controls its own pane's
canvas. herdr owns the other panes' PTYs and provides no primitive for a plugin
to composite a persistent popup over them (its only true-overlay placement is
transient — it is torn down the moment the invoking keybinding action
completes). So the area around the floating box is a solid fill matching your
terminal's background, not your dimmed workspace showing through.

Related version-specific quirks this plugin works around (herdr 0.7.1):

- `overlay`/`zoomed` pane placements vanish when opened from a keybinding
  action — hence the split-then-zoom approach.
- `plugin pane open --cwd <path>` makes the new pane exit immediately — hence
  the starting directory travels via the `HERDR_FLOAX_CWD` env var and the
  shell script `cd`s itself.

If a future herdr adds a persistent sized-overlay primitive, the app-drawn box
(and this whole limitation) could be replaced by it.

## Configuration

Copy `floax.conf.example` to the plugin config dir
(`herdr plugin config-dir herdr-floax`, i.e.
`~/.config/herdr/plugins/config/herdr-floax/floax.conf`):

```conf
width_pct = 98    # box width, % of the pane (20..100)
height_pct = 96   # box height, % of the pane (20..100)
key_hint = prefix+f   # shown in the bottom border (display only)
# backdrop = #102030  # optional override; defaults to the terminal background
# scrollback_lines = 10000  # embedded-terminal scrollback for PgUp/PgDn/wheel
```

Env overrides per invocation: `HERDR_FLOAX_WIDTH_PCT`, `HERDR_FLOAX_HEIGHT_PCT`,
`HERDR_FLOAX_KEY_HINT`, `HERDR_FLOAX_BACKDROP`, `HERDR_FLOAX_SCROLLBACK_LINES`.

## Install

From GitHub (builds with `cargo` at install time):

```sh
herdr plugin install Tyru5/herdr-floax

# Then install the default keybind (prefix+f) and reload herdr config:
bash "$(herdr plugin list --plugin herdr-floax --json | jq -r '.result.plugins[0].plugin_root')/scripts/install-keybinding.sh"
```

Or for local development:

```sh
# 1. Link the plugin (no GitHub round-trip):
herdr plugin link /path/to/herdr-floax

# 2. Install the default keybind (prefix+f), then reload herdr config:
bash /path/to/herdr-floax/scripts/install-keybinding.sh
```

Requires a Rust toolchain (`cargo`) to build, and
[`jq`](https://jqlang.github.io/jq/) for the toggle script
(`brew install jq` / `apt install jq`).

## Keybinding

The default is **`prefix+f`**. Change it any of these ways:

```sh
scripts/install-keybinding.sh prefix+g          # pass a key
HERDR_FLOAX_KEY=prefix+g scripts/install-keybinding.sh
```

…or add/edit the block by hand in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+f"
type = "plugin_action"
command = "herdr-floax.toggle"
description = "Toggle floating pane"
```

Reload herdr's config (or restart herdr) after changing it.

## Files

| File | Purpose |
|---|---|
| `herdr-plugin.toml` | Manifest: the `[[panes]]` entry (the TUI app) + the `toggle` `[[actions]]` + `[[build]]`. |
| `src/` | The Rust TUI: centered box, embedded shell PTY, vt100 rendering, resize. |
| `scripts/toggle-floating.sh` | The action: open ↔ reveal ↔ dismiss, per workspace. |
| `scripts/floating-shell.sh` | The embedded program: a login shell (detach-wrapped when possible). |
| `scripts/install-keybinding.sh` | Idempotently installs the default, overridable keybind. |
| `floax.conf.example` | Size/hint configuration template. |
