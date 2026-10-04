# Configuration

A config file decides what each statusbar line shows. Start with a small one:

```ini
[line.status]
text = " Ready#(fill: )#(datetime:%H:%M) "
```

Each `[line.NAME]` section adds a line. `text` is its template: `Ready` on the
left, the time on the right, and `#(fill: )` repeating a space between them.
Run `statusbar` to use the built-in config, or save this example as
`~/.config/statusbar/default.stbt` to use it instead.

## Add colors and a command

Use the shared palette and layout so modules match your config:

```ini
interval = 5

[colors]
text = default
muted = colour8
rule = colour8
accent = colour3
success = colour10
failure = colour1

[line.rule]
text = "#[fg=rule,dim]#(fill:─)#[default]"

[line.host]
default = "#(command:host)"
text = "#[fg=muted,bold]* Host: #[nobold]#(value) "
text .= "#[default,fg=rule,dim]#(fill:·)"
text .= "#[default,fg=muted] #(datetime:%a %d %b) #(datetime:%H:%M)#[default]"

[command.host]
run = hostname
interval = 60
```

`[command.host]` runs `hostname`; its first output line supplies the fallback
value. The label and fill stay in place when you use `statusbar update host TEXT`.
`[colors]` names colors used in styles. These defaults follow your terminal;
replace them with `#rrggbb` values for fixed colors. `text .=` appends to the
template to keep long lines readable. See the
[shared styling rules](../samples/themes/README.md#shared-styling-rules).

## Where statusbar finds the config

statusbar chooses its config path in this order:

1. `--config PATH` (use `-` to read from stdin)
2. `$STATUSBAR_CONFIG`
3. `$XDG_CONFIG_HOME/statusbar/default.stbt` if `XDG_CONFIG_HOME` is set;
   otherwise, `~/.config/statusbar/default.stbt`

Complete themes use `.stbt`; module fragments use `.stbm`. The default
startup file is `default.stbt`. An explicit path works with any name.

If the default file is missing, statusbar uses its built-in config:
[`samples/default.stbt`](../samples/default.stbt).

A config that cannot be used never keeps your shell from starting. If the
selected file is missing or unreadable, or if it is invalid, statusbar prints
the problem, starts the built-in config, and adds a failed line with the
diagnostic. This applies to `--config`, `$STATUSBAR_CONFIG`, stdin and the
default path alike. Your file is left untouched. Fix
it, then load it with `statusbar config < FILE`; a successful replacement
removes the warning line.

The built-in config is commented. Start from it:

```sh
mkdir -p ~/.config/statusbar
statusbar config show default > ~/.config/statusbar/default.stbt
```

Validate a draft file without starting a session or running its configured
commands:

```sh
statusbar config check ~/.config/statusbar/default.stbt
```

A valid file produces no output and exits 0. A syntax error exits 2 with its
file and line; a file that cannot be read exits 1. This checks config syntax;
check command dependencies and the layout in a session afterward.

`statusbar config show` prints the active config. Use `show startup` for the
original session config, `show default` for the built-in config, or `config path`
for the config path selected for a new session. See [usage](usage.md#config).

For generated configs and here-documents, see
[reading a config from stdin](usage.md#generate-a-config-on-the-fly).

## Find themes and modules by name

Inside a session, you can omit the extension:

```sh
statusbar config load ./my-theme       # also tries ./my-theme.stbt
statusbar config import ./disk         # also tries ./disk.stbm
```

For `load`, lookup tries the supplied path first, then appends `.stbt` if it
is not already present. `import` does the same with `.stbm`. Only missing
files trigger fallback: an existing but invalid, empty, unreadable or oversized
file reports an error.

For a bare filename, with no `/`, lookup searches each directory in order:

1. The current working directory.
2. `$XDG_CONFIG_HOME/statusbar`, or `~/.config/statusbar` when unset.
3. The compiled-in default theme or module directory, when configured.

Each directory tries the exact filename, then the filename with its extension.
Save personal themes and modules directly in your user config directory:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/statusbar"
cp ./my-theme.stbt ./disk.stbm "${XDG_CONFIG_HOME:-$HOME/.config}/statusbar/"
statusbar config load my-theme
statusbar config import disk
```

This example assumes `my-theme.stbt` and `disk.stbm` exist in the current
directory. User files override bundled files with the same name. Paths containing
`/`, including `./disk`, stay local to the supplied path. `-` still reads stdin,
and `config check` and startup `--config` use only the exact supplied path.

Homebrew builds configure both bundled directories, so these work from any
working directory without a matching local file:

```sh
statusbar config load pure
statusbar config import disk
```

For source builds, set the directories at build time:

```sh
zig build -Ddefault-themes-dir="$PWD/samples/themes" \
  -Ddefault-modules-dir="$PWD/samples/modules"
```

Use absolute paths for predictable lookup from any working directory.
Relative directory settings resolve from the command's working directory.
Without these options, lookup still searches the current and user config
directories.
`-Ddefault-themes-dir` also supplies the theme picker's default directory.
`-Dthemes-dir` and `-Dmodules-dir` choose installation destinations separately;
they do not configure lookup. Run `statusbar config load --help` or
`statusbar config import --help` to see the compiled-in directory.

## Inspect the parsed configuration

Use `config show --json` to inspect the active configuration. To inspect the
built-in config without starting a session, use `config show default --json`.
These commands do not execute configured commands.

With `jq` installed, list configured command names or inspect their intervals:

```sh
statusbar config show --json | jq -r '.commands[].name'
statusbar config show --json | jq '.commands'
```

The JSON object has `version`, `global`, `colors`, `lines`, `commands`, `push`
and `highlight`. The format version is currently `1`. Lines and commands stay
in declaration order and include their zero-based `index`. Intervals use
milliseconds; commands include their effective `interval_ms` and
`uses_global_interval`. Spinner frames are an array of strings.

Line and push `variants` contain `text`, `running`, `done`, `success` and
`failed`. Each template is an array of tagged parts, such as `{"text":"Ready"}`,
`{"command":"system.load"}` or `{"value":{}}`. Command references use full
names. A missing status template is `null`; an explicitly empty one is `[]`.
Lines also include the fallback source in `default` and its expanded
`default_variants`, or `null` when no fallback source is present. A missing
global style is `null`.

JSON is for inspection and cannot be loaded as a config. Omit `--json` to
save source text with comments and formatting. Both forms accept `current`,
`startup`, or `default`; the first two require a running session. Neither
includes runtime values or statuses. Use [`statusbar list --json`](list.md)
for live values, statuses, temporary lines and FIFO bindings.

## Replace the running config

Inside a session, you can replace the whole config. From the repository
checkout, for example:

```sh
statusbar config load ./samples/themes/tokyo-night.stbt
```

Replacement is strict: an invalid config leaves the active statusbar unchanged.
A successful replacement applies every setting, including its lines:

- Lines keep their identity by name. A configured line that is still present
  keeps its ID, its value set with `statusbar update`, and its status, and moves
  to its new position. A line still showing its default shows the new default.
- Lines the new config drops are removed, together with their FIFOs.
- Lines created by `statusbar new` stay below the configured lines, with their
  IDs, values and statuses. A replacement cannot add a configured line with the
  name of a temporary line.

Configured commands restart and establish their first values without a change
highlight. Because those commands are executable code, load trusted configs.

The file is read where you run `statusbar config`. The session receives its
contents and never needs access to that file. See
[config replacement details](usage.md#config-replacement-details) for the size
limit and [the protocol](osc-3110.md) for its terminal sequence.

## Add to the running config

Use `config import FILE` to add a module containing new lines, commands, and colors.
The [module library](../samples/modules/README.md) has ready-made modules with
native terminal colors. A module is a config fragment, for example:

```sh
statusbar config import - <<'EOF'
[line.extra.load]
text = "#[fg=extra.accent]#(command:extra.load)#[default]"

[command.extra.load]
run = uptime
interval = 10

[colors]
extra.accent = colour4
EOF
```

A fragment can contain several prefixes or unprefixed definitions. Names must
be unique within each kind: a line and a command can both be called `disk.usage`,
but two lines cannot share that name. Later imports may extend an existing
prefix. A standalone line cannot share its name with a group prefix: for
example, `[line.disk]` cannot coexist with `[line.disk.usage]`,
`[command.disk.fetch]`, or a color named `disk.accent`. Group prefixes cannot
be all digits. There are no module declarations, registration or import-time names.

The source text is preserved, including command scripts and comments. The
combined config must fit the 64 KiB limit. Modules that contain a line and
all their dependencies can also be checked directly with `config check`.

Fragments may refer to existing commands and colors. A fragment may also
contain only commands or colors. Global settings, `[push]`, and `[highlight]`
are not accepted by `config import`; use a complete replacement to change them.

The running session merges each addition against its latest config and
validates the complete result before applying it. Duplicate line, command,
or color names, temporary-line name conflicts, invalid config, and size-limit
failures leave the active config unchanged. New configured lines appear
after existing configured lines and before temporary lines. Existing line IDs,
values, statuses, FIFO bindings, command processes, schedules, and cached
output are preserved. Only new commands start immediately.

`config show current` includes the added source, including its comments.
The startup snapshot and saved file stay unchanged; save the current config
explicitly to reuse it in later sessions. Prefixes group related definitions
without wrapper markup; use `remove PREFIX` to remove a group.

Like replacement, sending an addition does not wait for an acknowledgement.
The CLI checks a snapshot first to report errors; the session checks again
when applying the request. Inspect `config show current` afterward. See
[the protocol](osc-3110.md) for limits and concurrent writes.

## Remove a prefix

Inside a running session:

```sh
statusbar remove disk
```

This removes the whole `disk.*` group: configured lines, commands, colors,
and temporary lines, regardless of which file added them. It does not match
`diskette.*`. If `disk` is a standalone line instead, it removes that line.
A standalone line and a group cannot share the same name.

Supply the top-level name, without dots. A numeric line ID selects its whole
first-segment group too: removing the ID of `disk.usage` removes `disk.*`.
Use `statusbar list` to inspect line names and IDs. With no argument,
`statusbar remove` removes only the newest temporary line; `--all` removes
only temporary lines. See [removing lines](push.md#remove-lines).

Removal rejects references from remaining templates to removed commands or
colors (including defaults even when a line does not use `#(value)`,
status variants, push templates and the global style). References produced
dynamically by a command are not inspected.
An unknown target or removal of the last configured line is also rejected.

The session checks and acknowledges the request over its control socket.
Successful removal prints nothing. Surviving line IDs, values, statuses,
FIFOs and unchanged command processes are preserved. Removed lines lose their
FIFO bindings, and removed configured commands are stopped. External commands
streaming into removed temporary lines keep running, but their later output
is ignored. The saved config file stays unchanged.

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
is required. Names are case-sensitive and use letters, digits, `_`, `-` and `.`,
up to 64 characters; names made only of digits are reserved for the IDs
statusbar assigns. Each name may be declared once.
Dots separate nonempty segments, such as `codex.usage`; leading, trailing
and consecutive dots are invalid. The first segment cannot be all digits.
A standalone line name cannot also be the prefix of a line, command, or color
group; use `disk.summary` alongside `disk.usage`, rather than `disk`.
Hyphens remain valid within names.

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
[`statusbar update`](set.md) or a [FIFO](bind.md) display literally at `#(value)`:
their `#(...)` and `#[...]` text is never interpreted, while ANSI colors and
OSC 8 hyperlinks still work.

Until a value is set, `#(value)` expands the line's `default` template, or
shows nothing if `default` is omitted. The fallback can include styles,
commands, dates, environment variables, and terminal properties. For example,
replace only `[line.prompt]` in a copy of the built-in config with this section.
Keep its `muted` and `accent` colors and `system.*` command definitions:

```ini
[line.prompt]
default = "#[fg=muted]#(command:system.user)@#[default]#[fg=accent,bold]#(command:system.host)#[default]"
text = "#(value)#(fill: )"
```

`statusbar update prompt "Hello"` replaces the fallback with `Hello`.
An explicit empty value (`statusbar update prompt ""`) also replaces it;
`statusbar update prompt --reset` restores the live fallback. A status template
that contains `#(value)` uses the same fallback.

`default` cannot refer to `#(value)` itself. Escape a literal `#` with `##`,
as in `##(value)` or `##[bold]`. Use `default .= "..."` to append to an earlier
`default =` in the same section. The combined source is limited to 1024 bytes.
Styles carry through the insertion point, so use `#[default]` to reset them
where needed. The expanded line must still have at most one fill and 16
non-nested tracking regions; these limits include every insertion of `default`.

The status is `normal`, `running`, `done`, `success` or `failed`. Configured
lines start `normal`; `statusbar update NAME --status STATE` changes it, and any
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
statusbar update build "compiling" --status running
statusbar update build "12 tests passed" --status success
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
temporary lines or a replacement config change the bar height. A value change
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
temporary lines to `right`, so a temporary line's name stays visible. Clipping never
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
[`statusbar new`](push.md). It accepts the same template keys as a line,
plus the spinner settings, but no `default`: temporary lines start empty.
Because it is not a `[line.NAME]` section, `push` remains a valid line name.

```ini
[push]
text    = "#[fg=brightblack]#(value)#(fill: )[#(name)]"
done    = "#[fg=brightblack]#(value)#(fill: )done [#(name)]"
success = "#[fg=brightblack]#(value)#(fill: )#[fg=green]✓#[fg=brightblack] [#(name)]"
failed  = "#[fg=brightblack]#(value)#(fill: )#[fg=red]✗#[fg=brightblack] [#(name)]"
```

Temporary lines start `running`, so they use `running` or `text` while input
arrives. When input ends, `new` sets `done` for a pipe; `new --` sets
`success` when the command exits with 0 and `failed` for any other exit
status or a signal. The statuses fall back as for configured lines. Without
`[push]`, temporary lines use `text = "#(value)#(fill: )[#(name)]"`. `keep`
defaults to `right`.

`#(name)` shows the explicit or generated name, such as `build` or `tmp-5`.
Reloading the config renders existing temporary lines with the new templates,
keeping their values and statuses.

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
when `new --` sets the command's `COLUMNS`. Frames are plain text, not markup;
put styles around `#(spinner)` in the template. A sequence can contain up to
128 frames and 1024 bytes, without control characters or standalone characters
that take no screen space.

Only visible lines whose status is `running` animate. They share one animation
timer, which stops when no such lines remain. Animation does not rerun commands
or reformat other lines. `#(spinner)` is empty for any other status; use status
templates for a static marker. Reloading the config starts the new sequence
from its first frame. As with other width changes, a reload does not update a
running command's `COLUMNS`.

See [the spinner sample](../samples/spinner.stbt) for a complete config.

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
  printf 'Host: '
  hostname -s
interval = 60
```

Only the first line of a command's latest output is displayed, as written:
its `#(...)` and `#[...]` text is not interpreted, while ANSI colors and OSC 8
hyperlinks work. Each command runs on its own schedule, so a slow one never
holds up the clock or other commands. One that runs past its interval (at
least five seconds) is killed. Commands run in the directory where statusbar
started, with stdin and stderr connected to `/dev/null`. `STATUSBAR_COLUMNS`
gives them the current statusbar width.
