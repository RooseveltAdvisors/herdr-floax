//! herdr-floax — a floating scratch shell for herdr, à la tmux-floax.
//!
//! LEGACY (0.3.x): this nested TUI is **no longer the pane command** and is not
//! built at plugin install. Since 0.4.0 the pane runs `scripts/floating-shell.sh`
//! directly so the shell stays on the primary screen and herdr's own copy mode
//! can scroll it; everything below describes the superseded 0.3.x design and is
//! kept only until this tree is deleted. See README.md and AGENTS.md.
//!
//! Runs as one persistent herdr pane (opened as a zoomed split by the toggle
//! script) and draws a centered, sized box hosting a real shell PTY. herdr has
//! no sized floating-pane primitive that survives a keybinding — its
//! `overlay`/`zoomed` placements are transient views torn down when the
//! invoking action finishes — so the floating look is drawn here, in-process,
//! the same way herdr-file-viewer draws its help overlay. The box hosts a live
//! PTY rather than static text, which is what makes it a shell and not a modal.
//!
//! KNOWN LIMITATION: the backdrop around the box is a solid fill this app
//! paints, NOT the user's live panes dimmed behind it (tmux-floax shows the
//! real session through its popup). A plugin only controls its own pane's
//! canvas — herdr owns the other panes' PTYs and has no primitive for
//! compositing a persistent popup over them. See README.md "Limitations".
//!
//! Input is byte-level stdin passthrough with one interception: plain
//! PgUp/PgDn and SGR wheel events drive the app's own scrollback view (see
//! SCROLLING below); everything else goes to the embedded shell verbatim (no
//! lossy key-event translation), so vim, REPLs, paste, and modifier chords
//! all behave. herdr's prefix key never reaches us — herdr intercepts it — so
//! the toggle keybinding keeps working while the shell is focused.
//!
//! The embedded program is scripts/floating-shell.sh (a login shell wrapped in
//! a per-workspace dtach/abduco/tmux session when available), so the session
//! survives the pane being closed on dismiss and re-attaches on reopen.
//!
//! SCROLLING: herdr cannot scroll this pane for you. The app draws on the
//! pane's alternate screen, so herdr captures no scrollback for it (its copy
//! mode has nothing to page through), and herdr's wheel routing degrades to
//! "alternate scroll" — turning the wheel into Up/Down arrow keys that land in
//! the embedded shell as history navigation. The embedded shell's history only
//! exists inside this process, so scrolling is owned here: the vt100 parser
//! keeps real scrollback, and the input layer (src/input.rs) intercepts plain
//! PgUp/PgDn (herdr only steals those for its own scrollback on primary-screen
//! panes) and SGR wheel events (enabled on the outer pane via ?1000h/?1006h,
//! which flips herdr's wheel routing from alternate-scroll to delivering mouse
//! events here).

mod config;
mod input;
mod ui;

use std::io::Read;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use ratatui::crossterm::execute;
use ratatui::crossterm::style::Print;
use ratatui::crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::prelude::*;

/// Events that wake the render loop. Input never appears here — it flows
/// straight from stdin to the PTY on its own thread.
enum Ev {
    /// The embedded terminal produced output; redraw.
    Output,
    /// SIGWINCH: recompute the box and resize the PTY.
    Winch,
    /// The embedded program exited (or the PTY hit EOF); quit.
    Exit,
}

fn io_err(e: impl std::fmt::Display) -> std::io::Error {
    std::io::Error::other(e.to_string())
}

fn restore_terminal() {
    let _ = execute!(std::io::stdout(), Print(input::MOUSE_DISABLE));
    let _ = disable_raw_mode();
    let _ = execute!(std::io::stdout(), LeaveAlternateScreen);
}

fn pty_size(inner: Rect) -> PtySize {
    PtySize {
        rows: inner.height,
        cols: inner.width,
        pixel_width: 0,
        pixel_height: 0,
    }
}

fn main() -> std::io::Result<()> {
    let cfg = config::Config::load();

    let (cols, rows) = ratatui::crossterm::terminal::size().unwrap_or((80, 24));
    let inner = ui::box_inner(Rect::new(0, 0, cols, rows), &cfg);

    // Spawn the embedded shell sized to the box interior.
    let pty = native_pty_system();
    let pair = pty.openpty(pty_size(inner)).map_err(io_err)?;

    let root = std::env::var("HERDR_PLUGIN_ROOT").unwrap_or_else(|_| ".".into());
    let mut cmd = CommandBuilder::new("bash");
    cmd.arg(format!("{root}/scripts/floating-shell.sh"));
    for (k, v) in std::env::vars() {
        cmd.env(k, v);
    }
    cmd.env("TERM", "xterm-256color");
    if let Ok(d) = std::env::var("HERDR_FLOAX_CWD") {
        if !d.is_empty() && std::path::Path::new(&d).is_dir() {
            cmd.cwd(d);
        }
    }
    let mut child = pair.slave.spawn_command(cmd).map_err(io_err)?;
    drop(pair.slave);

    let parser = Arc::new(Mutex::new(vt100::Parser::new(
        inner.height,
        inner.width,
        cfg.scrollback_lines,
    )));
    // The box interior in pane coordinates, kept current across resizes so the
    // input layer can translate mouse events into the embedded terminal's own
    // coordinate space.
    let geom = Arc::new(Mutex::new(inner));
    let (tx, rx) = mpsc::channel::<Ev>();

    // PTY output → vt100 parser → redraw.
    {
        let parser = Arc::clone(&parser);
        let tx = tx.clone();
        let mut reader = pair.master.try_clone_reader().map_err(io_err)?;
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => {
                        let _ = tx.send(Ev::Exit);
                        break;
                    }
                    Ok(n) => {
                        parser.lock().unwrap().process(&buf[..n]);
                        if tx.send(Ev::Output).is_err() {
                            break;
                        }
                    }
                }
            }
        });
    }

    // stdin → PTY, with scrollback-scroll interception (PgUp/PgDn, wheel).
    {
        let parser = Arc::clone(&parser);
        let geom = Arc::clone(&geom);
        let tx = tx.clone();
        let mut writer = pair.master.take_writer().map_err(io_err)?;
        std::thread::spawn(move || {
            // Reader: blocking stdin reads, forwarded as chunks. The
            // dispatcher holds a trailing partial escape sequence briefly so
            // a read split mid-sequence can still complete into a recognized
            // scroll/mouse token.
            let (chunk_tx, chunk_rx) = mpsc::channel::<Vec<u8>>();
            std::thread::spawn(move || {
                let mut stdin = std::io::stdin();
                let mut buf = [0u8; 2048];
                loop {
                    match stdin.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if chunk_tx.send(buf[..n].to_vec()).is_err() {
                                break;
                            }
                        }
                    }
                }
            });
            let redraw = move || {
                let _ = tx.send(Ev::Output);
            };
            input::dispatch(chunk_rx, &mut writer, &parser, &geom, &redraw);
        });
    }

    // Embedded program exit → quit.
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let _ = child.wait();
            let _ = tx.send(Ev::Exit);
        });
    }

    // SIGWINCH → re-layout.
    {
        let tx = tx.clone();
        let mut signals = signal_hook::iterator::Signals::new([signal_hook::consts::SIGWINCH])?;
        std::thread::spawn(move || {
            for _ in signals.forever() {
                if tx.send(Ev::Winch).is_err() {
                    break;
                }
            }
        });
    }

    // Terminal up. Restore on panic too, so a bug never wedges the pane raw.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        restore_terminal();
        default_hook(info);
    }));
    enable_raw_mode()?;
    execute!(
        std::io::stdout(),
        EnterAlternateScreen,
        Print(input::MOUSE_ENABLE)
    )?;
    let mut terminal = Terminal::new(CrosstermBackend::new(std::io::stdout()))?;

    let master = pair.master;
    loop {
        {
            let parser = parser.lock().unwrap();
            terminal.draw(|f| ui::draw(f, &cfg, parser.screen()))?;
        }
        let Ok(first) = rx.recv() else { break };
        let mut exit = matches!(first, Ev::Exit);
        let mut winch = matches!(first, Ev::Winch);
        // Coalesce bursts: one redraw per batch of PTY output.
        while let Ok(ev) = rx.try_recv() {
            match ev {
                Ev::Exit => exit = true,
                Ev::Winch => winch = true,
                Ev::Output => {}
            }
        }
        if exit {
            break;
        }
        if winch {
            let (c, r) = ratatui::crossterm::terminal::size().unwrap_or((cols, rows));
            let inner = ui::box_inner(Rect::new(0, 0, c, r), &cfg);
            let _ = master.resize(pty_size(inner));
            parser.lock().unwrap().set_size(inner.height, inner.width);
            *geom.lock().unwrap() = inner;
        }
    }

    restore_terminal();
    Ok(())
}
