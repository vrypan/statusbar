# Configuration

A config file decides what each statusbar line shows. Start with a small one:

```ini
[line.1]
left = " Ready "
right = %H:%M
```

Each `[line.N]` section adds a line. `left` and `right` place text on either
side. `%H:%M` shows the current time. Run `statusbar` to use the built-in
config, or save this example as `~/.config/statusbar/config` to use it instead.

## Add colors and a command

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
left  = " #[fg=accent,bold]#(host)#[default] #[fg=dim]· ready#[default]"
right = "%a %d %b  #[bold]%H:%M#[default] "

[command.host]
run      = hostname
interval = 60
```

`[command.host]` runs `hostname`, and `#(host)` puts its latest first line in
statusbar. `[colors]` names colors used by `style` and `#[...]` markup.

## Where statusbar finds the config

statusbar chooses its config path in this order:

1. `--config PATH` (use `-` to read from stdin)
2. `$STATUSBAR_CONFIG`
3. `$XDG_CONFIG_HOME/statusbar/config` if `XDG_CONFIG_HOME` is set; otherwise,
   `~/.config/statusbar/config`

If the selected default file is missing, statusbar uses its built-in config:
[`samples/default.config`](../samples/default.config). A missing file named by
`--config` or `$STATUSBAR_CONFIG` is an error. So is a malformed config:
statusbar reports the file, line, and problem before it touches the terminal.

The built-in config is commented. Its regular statusbar colors use the terminal's
palette, and its change highlight derives a pulse from each grapheme's colors.
Start from it:

```sh
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config
```

`statusbar config --print` prints the running session's active config. Use
`--print startup` for its original config, or `--print default` (also `--default`)
for the built-in config. `--path` shows the file a new session would load; see
[usage.md](usage.md#config).

For generated configs and here-documents, see
[reading a config from stdin](usage.md#generate-a-config-on-the-fly).

## Replace the running config

Inside a session, you can replace the whole config. From the repository
checkout, for example:

```sh
statusbar config < ./samples/themes/tokyo-night.config
```

An invalid config leaves the active statusbar unchanged. A successful replacement
applies every setting, including its number of `[line.N]` sections. Numbered-slot
overrides survive only where the same slot number exists in the new layout.
Lines created by `statusbar push` stay below the configured lines with their
IDs and content intact; they are separate from numbered slots.
Configured commands restart and establish their first values without a change
highlight. Because those commands are executable code, load trusted configs.

The file is read where you run `statusbar config`. The session receives its
contents and never needs access to that file. See
[config replacement details](usage.md#config-replacement-details) for the size
limit and [the protocol](osc-3110.md) for its terminal sequence.

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

At least `[line.1]` is required, even if it is empty.
Line sections define statusbar's desired height and must be consecutive from
`[line.1]`. They may appear in any order in the file and render in numeric
order. An empty section still reserves its line. The maximum is 65533 lines.

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

## `[line.push]`

Use `style` to set the base style of every line created by `statusbar push`:

```ini
[line.push]
style = fg=accent,bg=#1e1e2e
left = "#[fg=accent]› #[default]#(stream)"
right = "#[fg=#1e1e2e,bg=accent,bold] #(tag) [#(id)] #[default]"
```

`style` covers the whole line. `left` and `right` work like normal line
templates, with markup, clock conversions, and named or inline commands.
`#(stream)` inserts the current stream value in `left`; `#(tag)` and `#(id)`
insert the tag and numeric line ID in either template. Write `[#(id)]` for a
bracketed ID. Stream and tag values are inserted literally: their
`#[...]` text cannot change the template's markup, while stream ANSI colors
still work. The independent defaults are `left = "[#(id)] #(tag) > #(stream)"`
and `right = ""`. Either can be overridden without changing the other. If
`style` is omitted, pushed lines inherit the top-level `style`. This section does not
reserve a line or change numbered slots. Reloading the config updates pushed
lines already visible. A carriage-return update re-renders the current stream
value through `left`.

### Spinner

Set `spinner` to a sequence of characters and insert the current frame with
`#(spinner)` in either slot:

```ini
[line.push]
spinner = "-\|/"
spinner_interval = 0.1
left = "#(spinner) [#(id)] > #(stream)"

[line.push.done]
left = "· [#(id)] > #(stream)"

[line.push.success]
left = "✓ [#(id)] > #(stream)"
```

Each Unicode grapheme is one frame, so a character and its combining accents
or a joined emoji stay together. For a braille spinner, use
`spinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"`. Backslashes in config values are literal;
the ASCII example above needs only one backslash.

`spinner_interval` is the time between frames in seconds, defaults to `0.1`,
and accepts values from `0.1` to `86400`. These two settings belong in
`[line.push]`. An omitted or empty sequence disables the indicator; a single
character provides a static indicator while running.

Frames share the width of the widest character, with padding after narrower
frames. This keeps surrounding text steady and reserves the correct space
when `push --` sets the command's `COLUMNS`. Frames are plain text, not markup;
put styles around `#(spinner)` in the template. A sequence can contain up to
128 frames and 1024 bytes, without control characters or standalone characters
that take no screen space.

Only visible, running pushed lines using `#(spinner)` animate. They share one
animation timer, which stops when no such lines remain. Animation does not
rerun commands or reformat configured lines. `#(spinner)` becomes empty on
completion; use completion sections for a static marker. Reloading the config
starts the new sequence from its first frame. As with other width changes,
a reload does not update a running command's `COLUMNS`.

See [the spinner sample](../samples/spinner.config) for a complete config.

### Completion settings

Use `[line.push.done]` to change a line when its input ends. With
`statusbar push -- command`, `[line.push.success]` applies when the command
exits with zero, and `[line.push.failed]` applies for any other exit status
or termination by a signal.

```ini
[line.push]
left = "#(stream)"
right = "#(tag) [#(id)]"

[line.push.done]
right = "done · #(tag) [#(id)]"

[line.push.success]
right = "#[fg=green]✓#[default] #(tag) [#(id)]"

[line.push.failed]
right = "#[fg=red]exit #(exit_code)#[default] #(tag) [#(id)]"
```

Each section accepts `left`, `right`, and `style`. Settings inherit in this
order: `[line.push]`, then `done`, then `success` or `failed` when the command
result is known. Only specified settings are replaced; `right = ""` clears
an inherited right slot. A `style` value replaces the inherited style as a
whole. Section order in the file does not matter.

`#(exit_code)` inserts the command's numeric exit status. `#(signal)` inserts
the signal number if the command was terminated by a signal; the exit status
is then `128 + signal`. Both values are empty while running. For piped input,
`push` knows only that input ended: it applies `done` and leaves both values
empty. A command exiting normally with `130` has no signal value, whereas
SIGINT produces exit status `130` and signal `2`.

With `push --`, completion waits for both the end of output and the command's
exit. The final stream text remains available as `#(stream)`. Completion
settings do not add or remove lines. The result survives config reloads and
is retained when a line is hidden by a short terminal. If `push` exits before
sending its completion message, the line keeps its last received state.

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
Commands run in the directory where statusbar started, with stdin and stderr
connected to `/dev/null`. `STATUSBAR_COLUMNS` gives them the current statusbar width.

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

## Highlight changes

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
and `statusbar set` values cannot define regions. A whole grapheme belongs to
the region containing its first code point, even if a marker falls inside a
combining sequence.

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

## `[highlight]`: adaptive pulse

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
pulses = 2
```

`pulses` is the only highlight setting. It accepts 1, 2, or 3 and defaults to
2 when `[highlight]` is omitted.

At startup, statusbar queries the terminal's default foreground/background and
256 indexed colors with OSC 10, 11, and 4. It caches the replies; explicit RGB
colors need no query. Startup waits at most 0.5 seconds, shared with cursor
discovery. If either color of a grapheme is unknown, that grapheme uses bold
for the full effect duration instead of guessing the theme's colors.
Terminals or multiplexers that block these queries therefore still work.
Restart statusbar after changing the terminal theme to refresh the cache.

| Key | Meaning |
|-----|---------|
| `pulses` | 1–3 adaptive pulses, default 2; each lasts 1.2 seconds |

Older configurations must remove `effect`, `backgrounds`, `foreground`,
`foregrounds`, and `step`. These keys are rejected rather than ignored or
migrated. Ordinary markup colors and the `[colors]` palette are unchanged.
Resize and screen repair preserve an active pulse's position and deadline. If
safe repainting is temporarily blocked by child output, obsolete frames are
skipped rather than replayed.
