# Configuration

A config file decides what each statusbar line shows. Start with a small one:

```ini
[line.status]
text = " Ready#(fill: )#(datetime:%H:%M) "
```

Each `[line.NAME]` section adds a line. `text` is its template: `Ready` on the
left, the time on the right, and `#(fill: )` repeating a space between them.
Run `statusbar` to use the built-in config, or save this example as
`~/.config/statusbar/config.statusbar` to use it instead.

Coming from an older config with `[line.1]`, `left`, `right` and `rule`? See
the [migration guide](migration.md).

## Add colors and a command

```ini
interval = 5

[colors]
accent = #89b4fa
dim    = #7f849c
rule   = #45475a

[line.rule]
text = "#[fg=rule]#(fill:─)"

[line.host]
text = " #[fg=accent,bold]#(command:host)#[default] #[fg=dim]· ready#[default]"
text .= "#(fill: )"
text .= "#(datetime:%a %d %b)  #[bold]#(datetime:%H:%M)#[default] "

[command.host]
run      = hostname
interval = 60
```

`[command.host]` runs `hostname`, and `#(command:host)` shows the first line
of its latest output. `[colors]` names colors used by `#[...]` styles and the
top-level `style`. `text .=` appends to the template, which keeps long
templates readable.

## Where statusbar finds the config

statusbar chooses its config path in this order:

1. `--config PATH` (use `-` to read from stdin)
2. `$STATUSBAR_CONFIG`
3. `$XDG_CONFIG_HOME/statusbar/config.statusbar` if `XDG_CONFIG_HOME` is set;
   otherwise, `~/.config/statusbar/config.statusbar`

Shipped configs and themes use the `.statusbar` extension. An explicit path
works with any name.

If the default file is missing, statusbar uses its built-in config:
[`samples/default.statusbar`](../samples/default.statusbar). The old default
file, `statusbar/config`, is never loaded. When only that file exists,
statusbar starts with the built-in config and shows a line asking you to
migrate it.

A config that cannot be used never keeps your shell from starting. If the
selected file is missing or unreadable, or if it is invalid, statusbar prints
the problem, starts the built-in config, and adds a failed line with the
diagnostic, such as
`statusbar: line 4: left, right and rule were removed in ~/.config/...`. This
applies to `--config`, `$STATUSBAR_CONFIG`, stdin and the default path alike,
so statusbar is safe to use as a login shell. Your file is left untouched. Fix
it, then load it with `statusbar config < FILE`; a successful replacement
removes the warning line.

The built-in config is commented. Start from it:

```sh
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config.statusbar
```

Validate a draft file without starting a session or running its configured
commands:

```sh
statusbar config --check ~/.config/statusbar/config.statusbar
```

A valid file produces no output and exits 0. A syntax error exits 2 with its
file and line; a file that cannot be read exits 1. This checks config syntax;
check command dependencies and the layout in a session afterward.

`statusbar config --print` prints the running session's active config. Use
`--print startup` for its original config, or `--print default` (also
`--default`) for the built-in config. `--path` shows the file a new session
would load; see [usage.md](usage.md#config).

For generated configs and here-documents, see
[reading a config from stdin](usage.md#generate-a-config-on-the-fly).

## Replace the running config

Inside a session, you can replace the whole config. From the repository
checkout, for example:

```sh
statusbar config < ./samples/themes/tokyo-night.statusbar
```

Replacement is strict: an invalid config leaves the active statusbar unchanged.
A successful replacement applies every setting, including its lines:

- Lines keep their identity by name. A configured line that is still present
  keeps its ID, its value set with `statusbar set`, and its status, and moves
  to its new position. A line still showing its default shows the new default.
- Lines the new config drops are removed, together with their FIFOs.
- Lines created by `statusbar push` stay below the configured lines, with their
  IDs, values and statuses. A replacement cannot add a configured line with the
  name of a pushed line.

Configured commands restart and establish their first values without a change
highlight. Because those commands are executable code, load trusted configs.

The file is read where you run `statusbar config`. The session receives its
contents and never needs access to that file. See
[config replacement details](usage.md#config-replacement-details) for the size
limit and [the protocol](osc-3110.md) for its terminal sequence.

## Add to the running config

Use `--add PREFIX` to add a module containing new lines, commands, and colors.
The [module library](../samples/modules/README.md) has ready-made modules with
native terminal colors. A module is a config fragment, for example:

```sh
statusbar config --add extra <<'EOF'
[line.<module>-load]
text = "#[fg=<module>-accent]#(command:<module>-load)#[default]"

[command.<module>-load]
run = uptime
interval = 10

[colors]
<module>-accent = colour4
EOF
```

Every new line, command, and color name must start with `PREFIX-` and have a
nonempty suffix. Prefixes use 1–62 letters, digits, or underscores; the hyphen
separates the prefix from the rest of the name. `<module>` expands to the
prefix supplied to `--add`, so the example above defines `extra-load` and
`extra-accent`. Import the same file with another prefix to create a separate
instance. Fully written names such as `extra-load` remain supported and must
match the supplied prefix. You can add more definitions with the same prefix
later, provided their names are new.

Expansion happens once across the incoming module's text, including section
names, references, colors, command scripts, and comments. Write `<<module>>`
to keep a literal `<module>`. The expanded text must fit the combined config's
64 KiB limit. The existing config is not expanded again. Ordinary config
loading and `--check` do not expand placeholders; use them on a resolved
snapshot from `config --print current`.

Fragments may refer to existing commands and colors. A fragment may also
contain only commands or colors. Global settings, `[push]`, and `[highlight]`
are not accepted by `--add`; use a complete replacement to change them.

The running session merges each addition against its latest config and
validates the complete result before applying it. Duplicate line, command,
or color names, pushed-line name conflicts, invalid config, and size-limit
failures leave the active config unchanged. New configured lines appear
after existing configured lines and before pushed lines. Existing line IDs,
values, statuses, FIFO bindings, command processes, schedules, and cached
output are preserved. Only new commands start immediately.

`config --print current` includes the expanded source, including its comments.
The startup snapshot and saved file stay unchanged; save the current config
explicitly to reuse it in later sessions. Prefixes group related definitions
without wrapper markup. There is no group-removal command yet.

Like replacement, sending an addition does not wait for an acknowledgement.
The CLI checks a snapshot first to report errors; the session checks again
when applying the request. Inspect `config --print current` afterward. See
[the protocol](osc-3110.md) for limits and concurrent writes.

## Syntax

The config is a small INI-like language:

- `[SECTION]` starts a section. `KEY = VALUE` assigns a key.
- `KEY .= FRAGMENT` appends to a template key assigned earlier in the same
  section. Fragments join exactly, without adding spaces or newlines; only
  `text`, `running`, `done`, `success`, `failed` and configured-line `default`
  accept `.=`. Assigning
  the same key twice with `=` is an error.
- Wrap a value in double quotes to keep leading or trailing spaces. A quoted
  value may continue over several lines until a line ending in `"`.
- `KEY = |` takes the following indented lines as the value; see
  [commands](#commandname).
- Lines starting with `#` or `;` are comments. A `#` anywhere else is part of
  the value, since markup and colors use it, so a comment can't follow a
  value on the same line.

Errors name the line they occur on, including the line of the fragment that
holds a mistake in an appended template. The config is limited to 64 KiB.

## Top level

| Key        | Meaning                                                        |
|------------|----------------------------------------------------------------|
| `interval` | refresh for commands without their own, in seconds (default 5) |
| `style`    | base style of the whole bar, e.g. `fg=#cdd6f4,bg=#1e1e2e`      |

The base style applies to every cell a line leaves empty and to text after
`#[default]`. Style individual lines inline, with `#[...]` in their templates.

## `[colors]`

`name = color`, one per line. A name works anywhere markup takes a color, as
in `#[fg=accent]` or `style = fg=rule`. A value is any color the markup
accepts, but not another name.

## `[line.NAME]`

Each section adds one line. Lines appear in the order their sections are
first declared, whatever other sections come between them. At least one line
is required. Names are case-sensitive and use letters, digits, `_` and `-`,
up to 64 characters; names made only of digits are reserved for the IDs
statusbar assigns. Each name may be declared once.

| Key       | Meaning                                                            |
|-----------|--------------------------------------------------------------------|
| `text`    | the line's template; `#(value)` if omitted                         |
| `running` | template while the line's status is `running`                      |
| `done`    | template while its status is `done`                                |
| `success` | template while its status is `success`; falls back to `done`       |
| `failed`  | template while its status is `failed`; falls back to `done`        |
| `default` | fallback template expanded at `#(value)` until a value is set; restored by `--reset` |
| `keep`    | `left` (default) or `right`: which end survives when space runs out |

### Values and statuses

Every line has a value and a status. Values supplied with
[`statusbar set`](set.md) or a [FIFO](bind.md) display literally at `#(value)`:
their `#(...)` and `#[...]` text is never interpreted, while ANSI colors and
OSC 8 hyperlinks still work.

Until a value is set, `#(value)` expands the line's `default` template, or
shows nothing if `default` is omitted. The fallback can include styles,
commands, dates, environment variables, and terminal properties. For example,
using the configured `dim` and `accent` colors and `user` and `host` commands:

```ini
[line.prompt]
default = "#[fg=dim]#(command:user)@#[default]#[fg=accent,bold]#(command:host)#[default]"
text = "#(value)#(fill: )"
```

`statusbar set prompt "Hello"` replaces the fallback with `Hello`.
An explicit empty value (`statusbar set prompt ""`) also replaces it;
`statusbar set prompt --reset` restores the live fallback. A status template
that contains `#(value)` uses the same fallback.

`default` cannot refer to `#(value)` itself. Escape a literal `#` with `##`,
as in `##(value)` or `##[bold]`. Use `default .= "..."` to append to an earlier
`default =` in the same section. The combined source is limited to 1024 bytes.
Styles carry through the insertion point, so use `#[default]` to reset them
where needed. The expanded line must still have at most one fill and 16
non-nested tracking regions; these limits include every insertion of `default`.

The status is `normal`, `running`, `done`, `success` or `failed`. Configured
lines start `normal`; `statusbar set NAME --status STATE` changes it, and any
change is allowed. A status never changes the value.

The status selects the template. `normal` uses `text`. `running` and `done`
use their own template if set, otherwise `text`. `success` and `failed` use
their own template, then `done`, then `text`. A status template replaces
`text` completely; an explicitly empty one (`failed = ""`) shows nothing.

```ini
[line.build]
default = "no build yet"
text    = " #(value)"
running = " #[fg=yellow]● #(value)"
success = " #[fg=green]✓ #(value)"
failed  = " #[fg=red]✗ #(value)"
```

```sh
statusbar set build "compiling" --status running
statusbar set build "12 tests passed" --status success
```

## Templates

A template is text with explicit expressions:

| Expression | Shows |
|------------|-------|
| `#(value)` | the line's value |
| `#(name)` | the line's name, or its numeric ID when unnamed |
| `#(status)` | its status: `normal`, `running`, `done`, `success` or `failed` |
| `#(fill:PATTERN)` | repeats PATTERN across the free width; see [fill](#fill-and-alignment) |
| `#(command:NAME)` | the first line of `[command.NAME]`'s latest output |
| `#(datetime:FORMAT)` | local date and time using strftime(3), re-read every second, e.g. `#(datetime:%H:%M)` |
| `#(terminal:rows)`, `#(terminal:cols)` | the outer terminal window size |
| `#(terminal:content_rows)` | rows available to the child after the bar takes its rows |
| `#(env:NAME)` | environment variable NAME as statusbar started with it, e.g. `#(env:USER)`; empty if unset |
| `#(spinner)` | a spinner frame, in `[push]` templates; see [spinner](#spinner) |
| `#[...]` | a [style](#markup) |
| `#[track]...#[notrack]` | a [highlighted region](#highlight-changes) |
| `##` | a literal `#`: `##(value)` shows `#(value)` |

Anything else in `#(...)` is an error; there is no implicit shell command.
Define shell commands in `[command.NAME]` and show them with
`#(command:NAME)`. `%` is plain text outside `#(datetime:...)`; inside it,
`%%` writes a literal `%`. Command output, dates, environment values and names are displayed as
written, like values.

`terminal` values update on window resize; `content_rows` also updates when
pushed lines or a replacement config change the bar height. A value change
never stops dates, terminal sizes or commands from updating.

### Fill and alignment

`#(fill:PATTERN)` divides a template: text before it starts at the left edge,
text after it ends at the right edge, and the pattern repeats in between.
Only whole patterns repeat, measured in terminal cells, and any remainder is
blank. A template may have one fill. A template that is only a fill draws a
full-width rule:

```ini
[line.rule]
text = "#[fg=brightblack]#(fill:─)"

[line.status]
text = " left side#(fill:·)right side "
```

Without a fill, the text is left-aligned.

When the text does not fit, `keep` decides which end stays. With a fill,
`keep = left` shows the whole left side and as much of the right side as
remains; `keep = right` keeps the right side and shows the start of the left
side. Without a fill, `keep = left` shows the start and `keep = right` shows
the end, still starting at the left edge. Configured lines default to `left`,
pushed lines to `right`, so a pushed line's name stays visible. Clipping never
splits a character.

## Markup

Style text with tmux-like markup instead of escape codes:

```
#[fg=accent,bold]host#[default] #[fg=brightblack]·#[default] 3.73
```

Style markup holds attributes separated by commas or spaces. The standalone
tracking markers described below are template boundaries, not style
attributes.

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
- `default` or `none`: back to the bar's base `style`

Attributes apply in order, so `#[default,fg=muted]` resets and then sets a
color. Unknown attributes are ignored. A style carries on to the end of the
line, across expressions and the fill: the fill repeats in the style active
where it appears. For a line with its own background, start with the style
and use a fill, often of spaces, so the background covers the whole row:

```ini
[line.status]
text = "#[fg=#cdd6f4,bg=#1e1e2e] main#(fill: )12:00 "
```

Cells a line without a fill leaves empty use the base style.
Raw SGR escapes and OSC 8 hyperlinks work too; other escape sequences are
stripped.

## Highlight changes

Mark the part of a template you want to watch:

```ini
[line.weather]
text = "Weather #[track]#(command:weather)#[notrack]  Time #[track]#(datetime:%H:%M)#[notrack]"

[command.weather]
run = curl -fsS 'https://wttr.in/?format=%c%t'
interval = 300
```

Each marked region plays the shared `[highlight]` effect when its visible
content changes, then returns to its normal styling. Labels outside the markers,
the fill, and other regions keep their own appearance. Regions can grow, shrink,
and move; each change restarts only that region's timer.

Use exactly `#[track]` and `#[notrack]`, with up to 16 pairs per template.
Empty pairs are valid. Regions cannot nest, and markers cannot be combined with
style attributes or given names. A region may span expressions and the fill.
`#[default]` resets styling without ending tracking; write `##[track]` to
display the opening marker literally.

Markers come only from templates, including `default`. Explicit values and
command output cannot define regions. A whole grapheme belongs to the region
containing its first code point, even if a marker falls inside a combining sequence.

All commands used by a template must produce a first result before its regions
can highlight. Partial results appear silently; an empty first result also
counts. Later empty-to-nonempty changes can highlight. Identical content,
equivalent style escapes, and changes confined to a clipped part do nothing.
Changes in resolved colors, attributes, or hyperlinks count as content changes.

A change of the line's value or status establishes new baselines silently,
and cancels running effects, even when the text looks identical. Hidden or
empty regions store no pending animation to play later. Resize, clipping
caused by another value, and screen repair never start or restart effects.
Still-visible active regions retain their deadlines. Command reruns requested
by resize establish baselines silently; ordinary scheduled results remain
eligible. Repaints wait for safe terminal-output boundaries, so a busy
application may delay the effect or prevent a short highlight from appearing.

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
Resize and screen repair preserve an active pulse's position and deadline. If
safe repainting is temporarily blocked by child output, obsolete frames are
skipped rather than replayed.

## `[push]`

`[push]` holds the templates of lines created by
[`statusbar push`](push.md). It accepts the same template keys as a line,
plus the spinner settings, but no `default`: pushed lines start empty.
Because it is not a `[line.NAME]` section, `push` remains a valid line name.

```ini
[push]
text    = "#[fg=brightblack]#(value)#(fill: )[#(name)]"
done    = "#[fg=brightblack]#(value)#(fill: )done [#(name)]"
success = "#[fg=brightblack]#(value)#(fill: )#[fg=green]✓#[fg=brightblack] [#(name)]"
failed  = "#[fg=brightblack]#(value)#(fill: )#[fg=red]✗#[fg=brightblack] [#(name)]"
```

Pushed lines start `running`, so they use `running` or `text` while input
arrives. When input ends, `push` sets `done` for a pipe; `push --` sets
`success` when the command exits with 0 and `failed` for any other exit
status or a signal. The statuses fall back as for configured lines. Without
`[push]`, pushed lines use `text = "#(value)#(fill: )[#(name)]"`. `keep`
defaults to `right`.

`#(name)` shows the name given to `push`, or the line's numeric ID. Reloading
the config renders existing pushed lines with the new templates, keeping their
values and statuses.

### Spinner

Set `spinner` to a sequence of characters and insert the current frame with
`#(spinner)`:

```ini
[push]
spinner = "-\|/"
spinner_interval = 0.1
text    = "#(spinner) #(value)#(fill: )[#(name)]"
done    = "· #(value)#(fill: )[#(name)]"
success = "✓ #(value)#(fill: )[#(name)]"
```

Each Unicode grapheme is one frame, so a character and its combining accents
or a joined emoji stay together. For a braille spinner, use
`spinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"`. Backslashes in config values are literal;
the ASCII example above needs only one backslash.

`spinner_interval` is the time between frames in seconds, defaults to `0.1`,
and accepts values from `0.1` to `86400`. Both settings belong in `[push]`.
An omitted or empty sequence disables the indicator; a single character
provides a static indicator while running.

Frames share the width of the widest character, with padding after narrower
frames. This keeps surrounding text steady and reserves the correct space
when `push --` sets the command's `COLUMNS`. Frames are plain text, not markup;
put styles around `#(spinner)` in the template. A sequence can contain up to
128 frames and 1024 bytes, without control characters or standalone characters
that take no screen space.

Only visible lines whose status is `running` animate. They share one animation
timer, which stops when no such lines remain. Animation does not rerun commands
or reformat other lines. `#(spinner)` is empty for any other status; use status
templates for a static marker. Reloading the config starts the new sequence
from its first frame. As with other width changes, a reload does not update a
running command's `COLUMNS`.

See [the spinner sample](../samples/spinner.statusbar) for a complete config.

## `[command.NAME]`

| Key        | Meaning                                                     |
|------------|-------------------------------------------------------------|
| `run`      | shell command, run with `/bin/sh -c`                        |
| `interval` | seconds between runs (default: the top-level `interval`)    |

Show a command with `#(command:NAME)` in any template. A config holds up to
16 commands.

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

Only the first line of a command's latest output is displayed, as written:
its `#(...)` and `#[...]` text is not interpreted, while ANSI colors and OSC 8
hyperlinks work. Each command runs on its own schedule, so a slow one never
holds up the clock or other commands. One that runs past its interval (at
least five seconds) is killed. Commands run in the directory where statusbar
started, with stdin and stderr connected to `/dev/null`. `STATUSBAR_COLUMNS`
gives them the current statusbar width.
