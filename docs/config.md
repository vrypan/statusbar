# Configuration

statusbar reads the first available config source in this order:

1. `--config PATH`
2. `$STATUSBAR_CONFIG`
3. `$XDG_CONFIG_HOME/statusbar/config`
4. `~/.config/statusbar/config`

When neither default location has a file, statusbar uses its built-in config:
[`samples/default.config`](../samples/default.config). A missing file named by
`--config` or `$STATUSBAR_CONFIG` is an error. So is a malformed config:
statusbar reports the file, line, and problem before it touches the terminal.

The built-in config is commented. Its regular bar colors use the terminal's
palette, and its change highlight derives a pulse from each grapheme's colors.
Start from it:

```sh
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config
```

`statusbar config` prints the config statusbar would use after checking that
it parses, and `statusbar config --path` shows which file that is; see
[usage.md](usage.md#config).

## Example

```ini
interval = 5

[colors]
accent = #89b4fa
dim    = #7f849c
rule   = #45475a

[line.1]
rule  = ─
style = fg=rule

[line.2]
left  = " #[fg=accent,bold]#(hostname -s)#[default] #[fg=dim]·#[default] #(load)"
right = "%a %d %b  #[bold]%H:%M#[default] "

[command.load]
run      = sysctl -n vm.loadavg | awk '{print $2}'
interval = 10
```

## Top level

| Key        | Meaning                                                        |
|------------|----------------------------------------------------------------|
| `interval` | refresh for commands without their own, in seconds (default 5) |
| `style`    | style for lines without their own, e.g. `bg=#1e1e2e`           |

## `[colors]`

`name = color`, one per line. A name works anywhere markup takes a color, as
in `#[fg=accent]` or `style = fg=rule`. A value is any color the markup
accepts, but not another name.

## `[line.N]`

Line sections define the bar's desired height and must be consecutive from
`[line.1]`. They may appear in any order in the file and render in numeric
order. An empty section still reserves its row. The maximum is 65533 rows.

| Key     | Meaning                                         |
|---------|-------------------------------------------------|
| `left`  | template for the left slot                      |
| `right` | template for the right slot                     |
| `rule`  | repeat this pattern through space outside the slots, e.g. `─` |
| `style` | style for this line, e.g. `fg=rule`             |

Every line may have `left`, `right`, and `rule` together. The rule fills the
gap and any unused edge; without one those cells are spaces. Only complete
patterns are repeated and a remainder stays blank. When a line is too
narrow, the right slot is clipped first; the left slot is kept longest.
[`statusbar set`](set.md) addresses any slot by number.

## `[command.NAME]`

| Key        | Meaning                                                     |
|------------|-------------------------------------------------------------|
| `run`      | shell command, run with `/bin/sh -c`                        |
| `interval` | seconds between runs (default: the top-level `interval`)    |

For a readable multi-line value, write `= |` followed by indented lines. The
block ends at the next unindented key or section. Commands keep line breaks
for the shell; templates fold line breaks and tabs into spaces when rendered.
Typed values such as `interval` still need one valid value.

```ini
[command.example]
run = |
  first-command || exit
  second-command
interval = 60
```

Only the first line of a command's latest output is displayed. Each command
runs on its own schedule, so a slow one never holds up the clock or other
commands. One that runs past its interval (at least five seconds) is killed.

### Highlight changes

Mark the part of a left/right template you want to watch:

```ini
[line.1]
left = "Weather #[track]#(weather)#[notrack]  Time #[track]%H:%M#[notrack]"

[command.weather]
run = curl -fsS 'https://wttr.in/?format=%c%t'
interval = 300
```

Each marked region plays the shared `[highlight]` effect when its visible
content changes, then returns to its normal styling. Labels outside the markers,
rules, and other regions keep their own appearance. Regions can grow, shrink,
and move; each change restarts only that region's timer.

Use exactly `#[track]` and `#[notrack]`, with up to 16 pairs per slot. Empty
pairs are valid. Regions cannot nest, and markers cannot be combined with style
attributes or given names. `#[default]` resets styling without ending tracking;
write `##[track]` to display the opening marker literally.

Markers are compiled only from static left/right templates. Regions may include
text, clocks, named commands, and inline shell commands. Command output, rules,
`statusbar set` values, and `--exec` output cannot define regions. A whole
grapheme belongs to the region containing its first code point, even if a marker
falls inside a combining sequence.

All commands used by a slot must produce a first result before its regions can
highlight. Partial results appear silently; an empty first result also counts.
Later empty-to-nonempty changes can highlight. Identical content, equivalent
style escapes, and changes confined to a clipped suffix do nothing. Changes in
resolved colors, attributes, or hyperlinks count as content changes.

A manual slot override cancels its effects. Clearing the override silently
establishes new baselines, even when the text looks identical. Hidden or empty
regions store no pending animation to play later. Resize, clipping caused by
another value, and screen repair never start or restart effects. Still-visible
active regions retain their deadlines. Command reruns requested by resize
establish baselines silently; ordinary scheduled results remain eligible.
Repaints wait for safe terminal-output boundaries, so a busy application may
delay the effect or prevent a short highlight from appearing.

To migrate an older config, remove `track = true` (or `track = false`) from
`[command.NAME]` and wrap each desired use in `#[track]...#[notrack]`. The old
command key is rejected with migration guidance.

### `[highlight]`: adaptive pulse

With no highlight configuration, each marked grapheme pulses using its own
foreground and background colors. By default, two pulses play over 2.4 seconds.
Each pulse lasts 1.2 seconds. The animation rises from the original colors,
eases between peaks through a softer highlight, and returns to the original
only after the last pulse. Set `pulses` to 1, 2, or 3 (1.2, 2.4, or 3.6 seconds).
The background moves toward the text's lightness: dark backgrounds brighten,
including black, while light backgrounds darken. The foreground moves in the
same lightness direction across a wider hue-preserving range: gray text on a
dark background reaches near-white, while text on a light background moves
toward near-black. A safe range is chosen for the entire animation, rather
than correcting individual frames. Background movement is limited to prevent
crossing the original text lightness. Contrast checks keep
at least 75% of the original ratio and never cross below 4.5:1 unless the base
was already below it (in which case contrast cannot decrease).

Hue is retained where possible; saturated colors may lose some saturation to
stay within the displayable RGB range. Styling, hyperlinks, and whole Unicode
graphemes are preserved. At expiry, the exact original colors return, including
terminal defaults and palette indices.

```ini
[highlight]
effect = relative
pulses = 2
```

Use this explicit setting to try the adaptive effect while keeping existing
color-sequence entries. Those colors and `step` are ignored in relative mode.
The built-in config selects this effect; omitting `[highlight]` also selects
it unless custom colors are configured.

At startup, statusbar queries the terminal's default foreground/background and
256 indexed colors with OSC 10, 11, and 4. It caches the replies; explicit RGB
colors need no query. Startup waits at most 0.5 seconds, shared with cursor
discovery. If either color of a grapheme is unknown, that grapheme uses bold
for the full effect duration instead of guessing the theme's colors.
Terminals or multiplexers that block these queries therefore still work.
Restart statusbar after changing the terminal theme to refresh the cache.

### Custom color sequences

Existing color sequences still work. Without an explicit `effect`, specifying
colors selects sequence playback automatically. For example, the earlier warm
pulse remains available:

```ini
[highlight]
effect = sequence
backgrounds = #2c271a, #3d331b, #50411c, #6a551d, #84681f, #9e7b20, #8f701f, #765e1e, #5d4a1d, #44371b, #332c1a, #242019
foregrounds = #fce8c3, #fdebc4, #feefc8, #fff2ca, #fff4cc, #fff7d1, #fff5ce, #fff2ca, #feefc8, #fdebc4, #fce9c3, #fce8c3
step = 0.10
```

The colors ease from the normal dark background toward warm yellow and back
over 1.2 seconds. The foreground brightens with it. After the last step,
statusbar restores each cell's exact original foreground, background, bold,
italic and other attributes. Only affected rows repaint; commands are not
rerun for animation steps. The sequence does not loop, and another result
change restarts it at its first step.

| Key | Meaning |
|-----|---------|
| `effect` | `relative`, `sequence`, `bold`, or `auto` (default: custom colors select a sequence, otherwise relative) |
| `pulses` | Relative effect only: 1–3 pulses, default 2; each lasts 1.2 seconds. Ignored by sequence and bold effects. |
| `backgrounds` | One to 16 comma-separated `#RRGGBB` colors, in playback order |
| `foreground` | Optional temporary `#RRGGBB` text color, used for every step |
| `foregrounds` | Optional one-to-16 `#RRGGBB` colors; with backgrounds, counts must match |
| `step` | Seconds per step, from 0.05 to 5; defaults to 0.15 for color effects |

Use either singular `foreground` or plural `foregrounds`, not both. When both
plural sequences are present, their counts must match so every background has
one corresponding foreground. A `foregrounds`-only sequence is valid. Use one
background for a single flash, or just `foreground` for a text-color flash.
An omitted color channel retains each cell's original value.

Highlight colors must be exact `#RRGGBB` values; color names and `[colors]`
aliases are not accepted. Steps are discrete rather than interpolated. More
closely spaced shades and a shorter `step` produce a smoother effect, at the
cost of more row redraws.

For the old bold-only effect, set `effect = bold`; it lasts 0.5 seconds by
default, with `step` setting its duration. Resize and screen repair preserve
an active sequence's position and deadline. If safe repainting is temporarily
blocked by child output, obsolete steps are skipped rather than replayed.

Commands run in the directory where statusbar started, not your shell's,
with stdin and stderr on `/dev/null`. `STATUSBAR_COLUMNS` is the current
width and `STATUSBAR_LINES` is the configured row count, even while rows are
hidden.

## Templates

Templates mix text, markup and command output:

- `#(NAME)`: the first line of `[command.NAME]`'s latest output
- `#(anything else)`: runs as a shell command at the top-level `interval`,
  as in tmux; the same text used twice runs once
- `%H:%M`, `%a %d %b`: strftime(3) conversions, re-read every second;
  `%%` is a literal `%`
- `#[...]`: [markup](#markup)
- `#[track]...#[notrack]`: an independently [highlighted region](#highlight-changes)

## Syntax

- Wrap a value in double quotes to keep leading or trailing spaces.
- Any value may use a `|` block; see [commands](#commandname) for its syntax.
- Lines starting with `#` or `;` are comments. A `#` anywhere else is part of
  the value, since markup and colors use it, so a comment can't follow a
  value on the same line.

## Markup

Style text with tmux-like markup instead of escape codes:

```
#[fg=accent,bold]host#[default] #[fg=brightblack]·#[default] 3.73
```

Style markup holds attributes separated by commas or spaces. The standalone
tracking markers described above are template boundaries, not style attributes.

- `fg=COLOR`, `bg=COLOR`, where COLOR is one of
  - `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`,
    and `brightblack` … `brightwhite`: the terminal's palette, which follows
    its theme
  - `colour214` or `214`: the 256-color palette
  - `#rrggbb`: an exact color
  - a `[colors]` name
  - `default`: the terminal's own foreground or background
- `bold`, `dim`, `italics`, `underscore`, `blink`, `reverse`,
  `strikethrough`, `overline`, and `no…` (`nobold`) to turn each off
- `default` or `none`: back to the line's style

`##` is a literal `#`. Unknown attributes are ignored. Styles don't carry
across slots. Raw SGR escapes and OSC 8 hyperlinks work too; other escape
sequences are stripped.
