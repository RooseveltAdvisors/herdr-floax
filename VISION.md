# Vision

herdr-floax exists so that one keystroke summons a scratch shell over the current herdr workspace and the same keystroke dismisses it, without leaving herdr or disturbing the panes already there.
It removes a small but constant tax: reshaping the workspace or opening a new tab every time a task needs a place to run a command, read a log, or park some output.
It serves whoever runs herdr as their daily terminal multiplexer and wants a scratch shell that behaves like any other pane.
This repository is maintained at RooseveltAdvisors/herdr-floax as a fork of Tyru5/herdr-floax, and this vision is the fork's charter: why it was taken over, what it now carries, and what it must never drift away from.

## Why the fork exists

Upstream drew the floating shell as a nested ratatui TUI on the alternate screen, and that shape hit a wall herdr's input model would not let it cross: host scrollback stayed empty, herdr copy mode had nothing to target, and the plugin fought the terminal's own mouse handling.
The fork rebuilds the floating shell as a real herdr pane on the primary screen, so stock herdr 0.7.x input paths - copy mode (prefix+j), C-u/C-d half-page scroll, wheel scrollback, drag selection - work on floax history exactly as they do on any other pane.
It carries beyond upstream: the 0.4.0 real-pane architecture, per-workspace zoom preservation across toggles, optional command profiles in floax.conf, a safe fallback when herdr's injected binary path is stale, a shellcheck-clean regression suite, and CI that runs it.

## The experience it must create

One key, open-reveal-dismiss, one instance per workspace: absent it opens maximized, focused it closes, and focused-away it reveals and re-zooms.
The pane must never feel like a special surface: it is a login shell in a normal herdr split, and everything a pane can do, it can do.
When the environment surprises the script - a stale HERDR_BIN_PATH, a missing jq, no multiplexer installed - it degrades loudly and legibly, reporting the problem and exiting nonzero rather than failing silently.

## Principles for trade-offs

Primary-screen fidelity outranks visual polish: a zoomed split is chosen over herdr's popup placement precisely because copy mode targets tiled panes.
Host-owned history outranks plugin-owned conveniences: the plugin never puts itself between the user and herdr scrollback.
The alternate screen returns only by explicit request: tmux wrapping happens solely under HERDR_FLOAX_USE_TMUX=1, accepted at the cost of herdr copy mode.
Persistence is delegated, not invented: dtach or abduco carry the session across dismiss, and a plain fresh login shell is an honest default when neither exists.
Every behavior change earns a regression script before it earns a release.

## Non-goals

- No composited floating box or dimmed live backdrop; a herdr plugin controls only its own pane.
- No nested TUI and no plugin-owned scrollback.
- No persistence layer of its own; dtach and abduco already do that job.
- No Rust toolchain in the pane path; src/ remains only as legacy from 0.3.x.

## What must never diverge

The pane stays a real herdr terminal on the primary screen, with herdr copy mode and host scrollback functional; this is the fork's founding reason and is not negotiable.
The toggle contract stays open-reveal-dismiss, scoped per workspace, with any pre-existing workspace zoom saved and restored.
The workaround ledger stays in plain sight: each herdr 0.7.x quirk the plugin absorbs lives as a commented, tested decision, never as an invisible patch.
The plugin stays small enough to read in one sitting: shell scripts, a manifest, and tests, with no build step between checkout and behavior.

## Done well, one year out

The scratch shell is the reflex on every herdr workspace: prefix+f and a working shell is there, again and it is gone with zoom restored and the session intact where a multiplexer allows.
herdr releases may shift the ground under it; when they do, the fork absorbs each quirk as a documented workaround with a regression test, and CI stays green.
It remains the maintained home for the plugin, where the floating scratch shell keeps working because the fork understands exactly why it works.
