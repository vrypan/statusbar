# Config file

statusbar reads its config from the first of:

1. `--config PATH`
2. `$STATUSBAR_CONFIG`
3. `$XDG_CONFIG_HOME/statusbar/config`
4. `~/.config/statusbar/config`

When there is no file at the last two, default locations, statusbar uses its
built-in config, which is
[`samples/default.config`](../samples/default.config). A missing file given
with `--config` or `$STATUSBAR_CONFIG` is an error, and so is a file that
doesn't parse: statusbar stops with the file name, line number and problem,
before the terminal is touched.

The built-in config is commented and uses the terminal's own palette, so it
follows your theme. Start from it:

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

Line sections define the height and must be consecutive from `[line.1]`.
They may appear in any order in the file and render in numeric order. An
empty section still reserves its row. The maximum is 65533 rows.

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

The first line of the latest output is used. Each command runs on its own
schedule, so a slow one never holds up the clock or the others; one that
runs past its interval (at least 5 seconds) is killed.

Commands run in statusbar's working directory, not your shell's, with stdin
and stderr on `/dev/null`. `STATUSBAR_COLUMNS` is the current width and
`STATUSBAR_LINES` is the configured row count, even while rows are hidden.

## Templates

Templates mix text, markup and command output:

- `#(NAME)`: the first line of `[command.NAME]`'s latest output
- `#(anything else)`: runs as a shell command at the top-level `interval`,
  as in tmux; the same text used twice runs once
- `%H:%M`, `%a %d %b`: strftime(3) conversions, re-read every second;
  `%%` is a literal `%`
- `#[...]`: [markup](#markup)

## Syntax

- Wrap a value in double quotes to keep leading or trailing spaces.
- Lines starting with `#` or `;` are comments. A `#` anywhere else is part of
  the value, since markup and colors use it, so a comment can't follow a
  value on the same line.

## Markup

Style text with tmux-like markup instead of escape codes:

```
#[fg=accent,bold]host#[default] #[fg=brightblack]·#[default] 3.73
```

Each `#[...]` holds attributes separated by commas or spaces:

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
