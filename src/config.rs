//! Floating-box configuration: size percentages and the key hint shown in the
//! bottom border.
//!
//! Precedence: built-in defaults < `floax.conf` in `$HERDR_PLUGIN_CONFIG_DIR`
//! (KEY=VALUE lines) < `HERDR_FLOAX_*` environment variables. The env layer
//! lets the toggle script (or the user) override per-invocation without
//! touching the config file.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// Box width as a percentage of the pane, clamped to 20..=100.
    pub width_pct: u16,
    /// Box height as a percentage of the pane, clamped to 20..=100.
    pub height_pct: u16,
    /// The toggle key shown in the bottom-border hint (display only).
    pub key_hint: String,
    /// Optional backdrop fill override. `None` uses the terminal's default
    /// background color.
    pub backdrop: Option<(u8, u8, u8)>,
    /// Rows of scrollback the embedded terminal keeps. herdr captures no
    /// scrollback for this pane (the app draws on the alternate screen), so
    /// this buffer is what PgUp/PgDn and wheel scrolling page through.
    pub scrollback_lines: usize,
}

impl Default for Config {
    fn default() -> Self {
        // Generous defaults: the backdrop is dead space (see README
        // "Limitations" — it can't show the real workspace dimmed), so margin
        // is wasted space. Keep just enough inset to read as a floating box.
        Self {
            width_pct: 98,
            height_pct: 96,
            key_hint: "prefix+f".into(),
            backdrop: None,
            scrollback_lines: 10_000,
        }
    }
}

impl Config {
    /// Resolve config from the plugin config dir and the process environment.
    pub fn load() -> Self {
        let mut cfg = Self::default();
        if let Ok(dir) = std::env::var("HERDR_PLUGIN_CONFIG_DIR") {
            if let Ok(text) = std::fs::read_to_string(format!("{dir}/floax.conf")) {
                cfg.apply_conf(&text);
            }
        }
        cfg.apply_env(|k| std::env::var(k).ok());
        cfg
    }

    /// Apply `KEY=VALUE` lines (`#` comments and blank lines ignored).
    pub fn apply_conf(&mut self, text: &str) {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some((k, v)) = line.split_once('=') {
                self.set(k.trim(), v.trim());
            }
        }
    }

    /// Apply `HERDR_FLOAX_*` overrides from an env lookup (injected for tests).
    pub fn apply_env(&mut self, get: impl Fn(&str) -> Option<String>) {
        if let Some(v) = get("HERDR_FLOAX_WIDTH_PCT") {
            self.set("width_pct", &v);
        }
        if let Some(v) = get("HERDR_FLOAX_HEIGHT_PCT") {
            self.set("height_pct", &v);
        }
        if let Some(v) = get("HERDR_FLOAX_KEY_HINT") {
            self.set("key_hint", &v);
        }
        if let Some(v) = get("HERDR_FLOAX_BACKDROP") {
            self.set("backdrop", &v);
        }
        if let Some(v) = get("HERDR_FLOAX_SCROLLBACK_LINES") {
            self.set("scrollback_lines", &v);
        }
    }

    fn set(&mut self, key: &str, val: &str) {
        match key {
            "width_pct" => {
                if let Ok(n) = val.parse::<u16>() {
                    self.width_pct = clamp_pct(n);
                }
            }
            "height_pct" => {
                if let Ok(n) = val.parse::<u16>() {
                    self.height_pct = clamp_pct(n);
                }
            }
            "key_hint" => {
                if !val.is_empty() {
                    self.key_hint = val.to_string();
                }
            }
            "backdrop" => {
                if let Some(rgb) = parse_hex_color(val) {
                    self.backdrop = Some(rgb);
                }
            }
            "scrollback_lines" => {
                if let Ok(n) = val.parse::<usize>() {
                    // Cap so a typo can't turn the vt100 grid into a memory hog.
                    self.scrollback_lines = n.min(100_000);
                }
            }
            _ => {}
        }
    }
}

fn clamp_pct(n: u16) -> u16 {
    n.clamp(20, 100)
}

/// Parse `#rrggbb` (leading `#` optional) into an RGB triple.
fn parse_hex_color(s: &str) -> Option<(u8, u8, u8)> {
    let hex = s.trim().trim_start_matches('#');
    if hex.len() != 6 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some((
        u8::from_str_radix(&hex[0..2], 16).ok()?,
        u8::from_str_radix(&hex[2..4], 16).ok()?,
        u8::from_str_radix(&hex[4..6], 16).ok()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults() {
        let c = Config::default();
        assert_eq!((c.width_pct, c.height_pct), (98, 96));
    }

    #[test]
    fn conf_lines_parse_with_comments_and_junk() {
        let mut c = Config::default();
        c.apply_conf("# floax\nwidth_pct = 60\n\nheight_pct=45\nnot a kv line\nunknown=1\n");
        assert_eq!((c.width_pct, c.height_pct), (60, 45));
    }

    #[test]
    fn pct_clamped_and_bad_values_ignored() {
        let mut c = Config::default();
        c.apply_conf("width_pct=5\nheight_pct=999\n");
        assert_eq!((c.width_pct, c.height_pct), (20, 100));
        c.apply_conf("width_pct=banana\n");
        assert_eq!(c.width_pct, 20); // unchanged by unparsable value
    }

    #[test]
    fn env_overrides_conf() {
        let mut c = Config::default();
        c.apply_conf("width_pct=60\n");
        c.apply_env(|k| (k == "HERDR_FLOAX_WIDTH_PCT").then(|| "90".to_string()));
        assert_eq!(c.width_pct, 90);
    }

    #[test]
    fn key_hint_set_and_empty_ignored() {
        let mut c = Config::default();
        c.apply_conf("key_hint=prefix+g\nkey_hint=\n");
        assert_eq!(c.key_hint, "prefix+g");
    }

    #[test]
    fn backdrop_defaults_to_terminal_background() {
        assert_eq!(Config::default().backdrop, None);
    }

    #[test]
    fn backdrop_parses_hex_with_and_without_hash() {
        let mut c = Config::default();
        c.apply_conf("backdrop = #102030\n");
        assert_eq!(c.backdrop, Some((0x10, 0x20, 0x30)));
        c.apply_conf("backdrop = A1B2C3\n");
        assert_eq!(c.backdrop, Some((0xa1, 0xb2, 0xc3)));
    }

    #[test]
    fn backdrop_bad_values_ignored() {
        let mut c = Config::default();
        for bad in ["#12345", "#1234567", "not-a-color", "#zzzzzz", ""] {
            c.apply_conf(&format!("backdrop={bad}\n"));
            assert_eq!(c.backdrop, None, "should ignore {bad:?}");
        }
    }

    #[test]
    fn backdrop_env_override() {
        let mut c = Config::default();
        c.apply_env(|k| (k == "HERDR_FLOAX_BACKDROP").then(|| "#334455".to_string()));
        assert_eq!(c.backdrop, Some((0x33, 0x44, 0x55)));
    }

    #[test]
    fn scrollback_lines_default_conf_env_and_cap() {
        assert_eq!(Config::default().scrollback_lines, 10_000);
        let mut c = Config::default();
        c.apply_conf("scrollback_lines = 5000\n");
        assert_eq!(c.scrollback_lines, 5000);
        c.apply_env(|k| (k == "HERDR_FLOAX_SCROLLBACK_LINES").then(|| "2000".to_string()));
        assert_eq!(c.scrollback_lines, 2000);
        c.apply_conf("scrollback_lines = 999999999\nscrollback_lines = banana\n");
        assert_eq!(c.scrollback_lines, 100_000); // capped; junk ignored
    }
}
