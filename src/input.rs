//! Input interception for plugin-owned scrollback scrolling.
//!
//! herdr cannot scroll the floax pane for you: the app draws on the pane's
//! alternate screen, so herdr captures no scrollback for it (its copy mode has
//! nothing to page through), and herdr's wheel routing falls back to
//! "alternate scroll" — turning the wheel into Up/Down arrow keys that land in
//! the embedded shell as history navigation. The embedded shell's history only
//! ever existed inside this process, so scrolling has to be owned here.
//!
//! This module is the pure decision layer; `main.rs` wires it to stdin, the
//! PTY, and the vt100 parser. It recognizes two kinds of sequences in the raw
//! stdin byte stream:
//!
//!   - plain `PgUp` / `PgDn` (`ESC [ 5~` / `ESC [ 6~`). herdr intercepts those
//!     for its own scrollback only when the pane is NOT on the alternate
//!     screen, so on the floax pane they always reach us.
//!   - SGR mouse events (`ESC [ < btn ; x ; y M/m`). The app enables mouse
//!     reporting on its own pane (`?1000h` + `?1006h`), which flips herdr's
//!     wheel routing from alternate-scroll arrows to delivering SGR wheel
//!     events here.
//!
//! What a recognized sequence *does* depends on the embedded terminal's state,
//! mirroring herdr's own wheel routing:
//!
//!   - the embedded app enabled mouse reporting (vim etc.) -> forward verbatim
//!   - the embedded app is on ITS alternate screen (less, vim, an inner tmux)
//!     -> wheel becomes arrow keys (xterm "alternate scroll", same as herdr)
//!   - otherwise -> page/line-scroll our own vt100 scrollback view
//!
//! Everything else passes through to the PTY untouched. Any passthrough byte
//! while scrolled snaps the view back to the live bottom first, the way
//! tmux-floax's `copy-mode -e` style scrolling behaves when you start typing.

/// Mouse modes the app enables on its own (outer) pane: press/release
/// reporting (`?1000h`, includes wheel) in SGR encoding (`?1006h`). Enabling
/// these flips herdr's wheel routing for this pane from "alternate scroll"
/// (arrow keys into the shell) to delivering SGR mouse events here.
pub const MOUSE_ENABLE: &str = "\x1b[?1000h\x1b[?1006h";
pub const MOUSE_DISABLE: &str = "\x1b[?1006l\x1b[?1000l";

/// A recognized sequence extracted from the stdin stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Token {
    PageUp,
    PageDown,
    /// SGR mouse event. `button` is the raw button code (64 = wheel up,
    /// 65 = wheel down); `press` is false for the `m` (release) form.
    Mouse { button: u16, press: bool },
}

/// The result of matching the start of a buffer against known sequences.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Match {
    /// A complete sequence of this many bytes.
    Complete(Token, usize),
    /// The buffer is a proper prefix of a known sequence; wait for more bytes.
    Prefix,
    /// Not a known sequence; the bytes are passthrough input.
    Miss,
}

pub const PAGE_UP: &[u8] = b"\x1b[5~";
pub const PAGE_DOWN: &[u8] = b"\x1b[6~";
const SGR_PREFIX: &[u8] = b"\x1b[<";

/// Classify the bytes at the start of `buf`.
pub fn match_token(buf: &[u8]) -> Match {
    for (seq, tok) in [(PAGE_UP, Token::PageUp), (PAGE_DOWN, Token::PageDown)] {
        if buf.starts_with(seq) {
            return Match::Complete(tok, seq.len());
        }
        if seq.starts_with(buf) && buf.len() < seq.len() {
            return Match::Prefix;
        }
    }
    match_sgr_mouse(buf)
}

/// Match an SGR mouse sequence `ESC [ < b ; x ; y (M|m)` at the start of `buf`.
fn match_sgr_mouse(buf: &[u8]) -> Match {
    if buf.len() <= SGR_PREFIX.len() && *buf == SGR_PREFIX[..buf.len()] {
        return Match::Prefix;
    }
    if !buf.starts_with(SGR_PREFIX) {
        return Match::Miss;
    }
    let body = &buf[SGR_PREFIX.len()..];
    // Fields are `button;x;y` (digits and ';') terminated by 'M' (press) or
    // 'm' (release).
    let mut len = 0;
    for &byte in body {
        len += 1;
        if byte == b'M' || byte == b'm' {
            let press = byte == b'M';
            let fields = &body[..len - 1];
            let mut it = fields.split(|&c| c == b';');
            let (Some(button), Some(_x), Some(_y)) = (
                parse_num(it.next()),
                parse_num(it.next()),
                parse_num(it.next()),
            ) else {
                return Match::Miss;
            };
            if it.next().is_some() {
                return Match::Miss;
            }
            return Match::Complete(Token::Mouse { button, press }, SGR_PREFIX.len() + len);
        }
        if !byte.is_ascii_digit() && byte != b';' {
            return Match::Miss;
        }
    }
    Match::Prefix
}

fn parse_num(field: Option<&[u8]>) -> Option<u16> {
    let s = std::str::from_utf8(field?).ok()?;
    if s.is_empty() {
        return None;
    }
    s.parse().ok()
}

/// Length of the longest suffix of `buf` that is a proper prefix of a known
/// sequence — i.e. the bytes that must be held back from passthrough because
/// the next read might complete them into a recognized sequence.
pub fn partial_len(buf: &[u8]) -> usize {
    let max = 24; // longer than any realistic SGR mouse sequence
    let start = buf.len().saturating_sub(max);
    for i in start..buf.len() {
        if matches!(match_token(&buf[i..]), Match::Prefix) {
            return buf.len() - i;
        }
    }
    0
}

/// What the dispatcher should do with a recognized token, given the embedded
/// terminal's current state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Forward the raw sequence to the embedded PTY unchanged.
    Forward,
    /// Drop the sequence (e.g. a click the embedded app didn't ask for).
    Drop,
    /// Scroll our own scrollback view up (older) by this many rows.
    ScrollUp(usize),
    /// Scroll our own scrollback view down (newer) by this many rows.
    ScrollDown(usize),
    /// Embedded alt-screen app without mouse reporting: turn the wheel into
    /// arrow keys (`true` = up), like xterm alternate scroll.
    WheelAsArrows { up: bool, lines: usize },
}

/// Embedded-terminal state the scroll decision depends on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EmbeddedState {
    /// The embedded app switched to its own alternate screen (vim, less,
    /// an inner tmux). vt100 produces no scrollback there.
    pub alt_screen: bool,
    /// The embedded app enabled mouse reporting; it wants mouse events.
    pub mouse_reporting: bool,
}

/// Wheel scroll distance in rows per notch.
pub const WHEEL_LINES: usize = 3;

/// Decide what a recognized token does.
///
/// `page` is the number of visible rows (a full PgUp/PgDn step).
pub fn decide(tok: Token, st: EmbeddedState, page: usize) -> Action {
    match tok {
        Token::PageUp | Token::PageDown => {
            // Full-screen/mouse apps get their PgUp/PgDn (vim pages with it).
            if st.alt_screen || st.mouse_reporting {
                Action::Forward
            } else if tok == Token::PageUp {
                Action::ScrollUp(page.max(1))
            } else {
                Action::ScrollDown(page.max(1))
            }
        }
        Token::Mouse { button, .. } => {
            if st.mouse_reporting {
                // The embedded app asked for mouse events; it gets all of them.
                return Action::Forward;
            }
            match button {
                64 => {
                    if st.alt_screen {
                        Action::WheelAsArrows {
                            up: true,
                            lines: WHEEL_LINES,
                        }
                    } else {
                        Action::ScrollUp(WHEEL_LINES)
                    }
                }
                65 => {
                    if st.alt_screen {
                        Action::WheelAsArrows {
                            up: false,
                            lines: WHEEL_LINES,
                        }
                    } else {
                        Action::ScrollDown(WHEEL_LINES)
                    }
                }
                // Clicks, releases, horizontal wheel: nothing to do with them.
                _ => Action::Drop,
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Runtime: the stdin dispatcher.
// ---------------------------------------------------------------------------

use std::io::Write;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How long a trailing partial escape sequence is held before being passed
/// through as-is (herdr delivers each key event as one write, so in practice
/// this only fires for a bare ESC keypress).
const PARTIAL_TIMEOUT: Duration = Duration::from_millis(25);

/// Consume stdin chunks and drive the embedded PTY: recognized scroll/mouse
/// sequences act on the vt100 scrollback view (or are translated), everything
/// else is written to the PTY verbatim. `redraw` wakes the render loop after
/// any scroll change. Returns when the chunk channel closes (stdin EOF).
pub fn dispatch(
    rx: mpsc::Receiver<Vec<u8>>,
    writer: &mut impl Write,
    parser: &Arc<Mutex<vt100::Parser>>,
    redraw: &dyn Fn(),
) {
    let mut pending: Vec<u8> = Vec::new();
    loop {
        if pending.is_empty() {
            match rx.recv() {
                Ok(chunk) => pending.extend_from_slice(&chunk),
                Err(_) => return,
            }
        } else {
            match rx.recv_timeout(PARTIAL_TIMEOUT) {
                Ok(chunk) => pending.extend_from_slice(&chunk),
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    // The held bytes were a bare ESC (or a truncated
                    // sequence): they are input, not a scroll token.
                    let rest = std::mem::take(&mut pending);
                    passthrough(&rest, writer, parser, redraw);
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    let rest = std::mem::take(&mut pending);
                    passthrough(&rest, writer, parser, redraw);
                    return;
                }
            }
        }
        process(&mut pending, writer, parser, redraw);
    }
}

/// Drain every complete token from `pending`, leaving any partial sequence.
fn process(
    pending: &mut Vec<u8>,
    writer: &mut impl Write,
    parser: &Arc<Mutex<vt100::Parser>>,
    redraw: &dyn Fn(),
) {
    loop {
        match match_token(pending) {
            // Wait for more bytes (also the empty-buffer case).
            Match::Prefix => return,
            Match::Miss => {
                let hold = partial_len(pending);
                let n = pending.len() - hold;
                let out: Vec<u8> = pending.drain(..n).collect();
                if !out.is_empty() {
                    passthrough(&out, writer, parser, redraw);
                }
                // If a partial suffix was held, the next iteration sees
                // Match::Prefix and returns; otherwise the buffer is empty
                // and match_token reports Prefix as well.
            }
            Match::Complete(tok, len) => {
                let seq: Vec<u8> = pending.drain(..len).collect();
                handle_token(tok, &seq, writer, parser, redraw);
            }
        }
    }
}

/// Plain input for the shell: snap the scroll view back to the live bottom
/// first (terminal convention — typing always returns you to the prompt),
/// then write through.
fn passthrough(
    bytes: &[u8],
    writer: &mut impl Write,
    parser: &Arc<Mutex<vt100::Parser>>,
    redraw: &dyn Fn(),
) {
    snap_to_bottom(parser, redraw);
    if writer.write_all(bytes).is_err() {
        return;
    }
    let _ = writer.flush();
}

fn snap_to_bottom(parser: &Arc<Mutex<vt100::Parser>>, redraw: &dyn Fn()) {
    let mut p = parser.lock().unwrap();
    if p.screen().scrollback() == 0 {
        return;
    }
    p.set_scrollback(0);
    drop(p);
    redraw();
}

/// Apply one recognized token per the embedded terminal's state.
fn handle_token(
    tok: Token,
    seq: &[u8],
    writer: &mut impl Write,
    parser: &Arc<Mutex<vt100::Parser>>,
    redraw: &dyn Fn(),
) {
    let (action, app_cursor) = {
        let p = parser.lock().unwrap();
        let s = p.screen();
        let st = EmbeddedState {
            alt_screen: s.alternate_screen(),
            mouse_reporting: s.mouse_protocol_mode() != vt100::MouseProtocolMode::None,
        };
        let page = usize::from(s.size().0);
        (decide(tok, st, page), s.application_cursor())
    };
    match action {
        Action::Forward => {
            let _ = writer.write_all(seq);
            let _ = writer.flush();
        }
        Action::Drop => {}
        Action::ScrollUp(n) => scroll_by(parser, n as isize, redraw),
        Action::ScrollDown(n) => scroll_by(parser, -(n as isize), redraw),
        Action::WheelAsArrows { up, lines } => {
            // xterm alternate scroll, honoring the embedded app's cursor mode.
            let arrow: &[u8] = match (up, app_cursor) {
                (true, true) => b"\x1bOA",
                (true, false) => b"\x1b[A",
                (false, true) => b"\x1bOB",
                (false, false) => b"\x1b[B",
            };
            for _ in 0..lines {
                if writer.write_all(arrow).is_err() {
                    break;
                }
            }
            let _ = writer.flush();
        }
    }
}

/// Move the scrollback view by `delta` rows (positive = older). vt100 clamps
/// at the top; zero is the live bottom.
fn scroll_by(parser: &Arc<Mutex<vt100::Parser>>, delta: isize, redraw: &dyn Fn()) {
    let mut p = parser.lock().unwrap();
    let cur = p.screen().scrollback();
    let new = if delta >= 0 {
        cur.saturating_add(delta as usize)
    } else {
        cur.saturating_sub(delta.unsigned_abs())
    };
    if new != cur {
        p.set_scrollback(new);
        drop(p);
        redraw();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHELL: EmbeddedState = EmbeddedState {
        alt_screen: false,
        mouse_reporting: false,
    };
    const VIM: EmbeddedState = EmbeddedState {
        alt_screen: true,
        mouse_reporting: false,
    };
    const MOUSE_APP: EmbeddedState = EmbeddedState {
        alt_screen: false,
        mouse_reporting: true,
    };

    #[test]
    fn recognizes_page_keys() {
        assert_eq!(match_token(b"\x1b[5~"), Match::Complete(Token::PageUp, 4));
        assert_eq!(match_token(b"\x1b[6~"), Match::Complete(Token::PageDown, 4));
    }

    #[test]
    fn recognizes_sgr_wheel() {
        assert_eq!(
            match_token(b"\x1b[<64;12;34M"),
            Match::Complete(
                Token::Mouse {
                    button: 64,
                    press: true
                },
                12
            )
        );
        assert_eq!(
            match_token(b"\x1b[<65;1;1m"),
            Match::Complete(
                Token::Mouse {
                    button: 65,
                    press: false
                },
                10
            )
        );
    }

    #[test]
    fn prefix_detection_for_split_reads() {
        assert_eq!(match_token(b""), Match::Prefix);
        assert_eq!(match_token(b"\x1b"), Match::Prefix);
        assert_eq!(match_token(b"\x1b[5"), Match::Prefix);
        assert_eq!(match_token(b"\x1b[<"), Match::Prefix);
        assert_eq!(match_token(b"\x1b[<64;12"), Match::Prefix);
        assert_eq!(match_token(b"\x1b[<64;12;3"), Match::Prefix);
    }

    #[test]
    fn no_match_for_unrelated_input() {
        assert_eq!(match_token(b"a"), Match::Miss);
        assert_eq!(match_token(b"\x1b[A"), Match::Miss); // Up arrow
        assert_eq!(match_token(b"\x1bOA"), Match::Miss); // app-cursor Up
        assert_eq!(match_token(b"\x1b[5;5~"), Match::Miss); // Ctrl+PgUp: not ours
        assert_eq!(match_token(b"\x1b[<64M"), Match::Miss); // missing fields
    }

    #[test]
    fn partial_len_holds_only_real_prefixes() {
        assert_eq!(partial_len(b"hello"), 0);
        assert_eq!(partial_len(b"hello\x1b"), 1);
        assert_eq!(partial_len(b"hello\x1b[<6"), 4);
        assert_eq!(partial_len(b"\x1b[A\x1b"), 1); // complete arrow + trailing ESC
        assert_eq!(partial_len(b"\x1b[A"), 0);
    }

    #[test]
    fn shell_state_scrolls_own_scrollback() {
        assert_eq!(decide(Token::PageUp, SHELL, 40), Action::ScrollUp(40));
        assert_eq!(decide(Token::PageDown, SHELL, 40), Action::ScrollDown(40));
        assert_eq!(
            decide(Token::Mouse { button: 64, press: true }, SHELL, 40),
            Action::ScrollUp(WHEEL_LINES)
        );
        assert_eq!(
            decide(Token::Mouse { button: 65, press: true }, SHELL, 40),
            Action::ScrollDown(WHEEL_LINES)
        );
    }

    #[test]
    fn embedded_alt_screen_gets_page_keys_and_arrow_wheel() {
        assert_eq!(decide(Token::PageUp, VIM, 40), Action::Forward);
        assert_eq!(decide(Token::PageDown, VIM, 40), Action::Forward);
        assert_eq!(
            decide(Token::Mouse { button: 64, press: true }, VIM, 40),
            Action::WheelAsArrows {
                up: true,
                lines: WHEEL_LINES
            }
        );
        assert_eq!(
            decide(Token::Mouse { button: 65, press: true }, VIM, 40),
            Action::WheelAsArrows {
                up: false,
                lines: WHEEL_LINES
            }
        );
    }

    #[test]
    fn mouse_reporting_app_gets_everything() {
        assert_eq!(decide(Token::PageUp, MOUSE_APP, 40), Action::Forward);
        assert_eq!(
            decide(Token::Mouse { button: 64, press: true }, MOUSE_APP, 40),
            Action::Forward
        );
        assert_eq!(
            decide(Token::Mouse { button: 0, press: true }, MOUSE_APP, 40),
            Action::Forward
        );
    }

    #[test]
    fn clicks_without_mouse_reporting_are_dropped() {
        assert_eq!(
            decide(Token::Mouse { button: 0, press: true }, SHELL, 40),
            Action::Drop
        );
        assert_eq!(
            decide(Token::Mouse { button: 0, press: false }, SHELL, 40),
            Action::Drop
        );
        assert_eq!(
            decide(Token::Mouse { button: 66, press: true }, SHELL, 40),
            Action::Drop
        );
    }
}
