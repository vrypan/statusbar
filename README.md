# statusbar

A PTY proxy that keeps a one- or two-line status bar at the bottom (or top,
with `-p top`) of the terminal and runs a shell (or any command) in a pty
that is that much shorter.

    zig build -Doptimize=ReleaseSafe
    ./zig-out/bin/statusbar                      # bar from the config file
    ./zig-out/bin/statusbar -e 'date "+%H:%M"'   # or from a single command

## Config file

statusbar reads `--config PATH`, else `$STATUSBAR_CONFIG`, else
`$XDG_CONFIG_HOME/statusbar/config`, else `~/.config/statusbar/config`.
`samples/default.config` is a commented starting point:

    mkdir -p ~/.config/statusbar
    cp samples/default.config ~/.config/statusbar/config

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
right = "#[italics]#(git -C ~/src/project branch --show-current)#[default]  %H:%M "

[command.load]
run      = sysctl -n vm.loadavg | awk '{print $2}'
interval = 10
```

**Top level**

| Key        | Meaning                                                        |
|------------|----------------------------------------------------------------|
| `lines`    | bar height, 1 or 2 (default: the highest `[line.N]`)           |
| `position` | `bottom` (default) or `top`                                    |
| `interval` | refresh for commands without their own, in seconds (default 5) |
| `style`    | style for lines without their own, e.g. `bg=#1e1e2e`           |

**`[colors]`**: `name = color`. A name works anywhere markup takes a color,
as in `#[fg=accent]` or `style = fg=rule`.

**`[line.1]`, `[line.2]`**: line 1 is the bar's upper row.

- `left`, `right`: templates for the two slots
- `rule`: fill the line with this text instead, e.g. `─`
- `style`: style for this line

When a line is too narrow, the right slot is clipped first; the left slot is
kept longest.

**`[command.NAME]`**: `run`, a shell command, and optionally `interval`.

**Templates** mix text, markup and command output:

- `#(NAME)`: the first line of `[command.NAME]`'s latest output
- `#(anything else)`: runs as a shell command at the default interval, as in
  tmux; the same text used twice runs once
- `%H:%M`, `%a %d %b`: strftime(3), re-read every second; `%%` is a literal `%`

Each command runs on its own schedule, so a slow one never holds up the clock
or the others. Commands run in statusbar's working directory and see
`STATUSBAR_COLUMNS` and `STATUSBAR_LINES`.

Wrap a value in double quotes to keep leading or trailing spaces. Lines
starting with `#` or `;` are comments; a `#` elsewhere is part of the value.

Command-line flags override the config. `--exec` replaces the `[line.N]`
sections, while the config's colors and other options still apply.

## Markup

Style text with tmux-like markup instead of escape codes:

    #[fg=accent,bold]host#[default] #[fg=brightblack]·#[default] 3.73

- `fg=` / `bg=`: `black` … `white`, `brightblack` … `brightwhite`,
  `colour214` (or `214`), `#rrggbb`, a `[colors]` name, or `default` (the
  terminal's own color)
- `bold dim italics underscore blink reverse strikethrough overline`, and
  `no…` to turn each off
- `default` or `none`: back to the line's style
- `##` is a literal `#`

Styles don't carry across slots. Raw SGR escapes work too.

## Updating the bar from inside the session

Programs running in the session can replace the left or right slot of the
bar's last text line (the last one that isn't a rule):

    statusbar set left  "$(starship module directory)"
    statusbar set right "main ✓"
    statusbar set right                     # restore the template

Words are joined with spaces. Outside a statusbar session the command writes
nothing and exits successfully, so hooks can call it unconditionally.

It writes to `/dev/tty`, not stdout, so it also works from a prompt tool that
captures command output. In starship:

```toml
[custom.statusbar]
command = "statusbar set right \"$(git branch --show-current)\""
when    = true
```

To move starship's prompt into the bar, add `eval "$(statusbar init zsh)"`
to `~/.zshrc`; see [docs/starship.md](docs/starship.md).

Or on every prompt in zsh:

```zsh
statusbar_precmd() { statusbar set left "$(starship module directory)"; }
precmd_functions+=(statusbar_precmd)
```

Under the hood it sends iTerm2's user-variable sequence, which WezTerm also
understands:

    ESC ] 1337 ; SetUserVar=StatusBarLeft=<base64> BEL

statusbar keeps `StatusBarLeft` and `StatusBarRight` for itself and forwards
every other OSC, including other user variables, to the terminal. Anything
that can print to the terminal can send them, so treat bar content as
display-only.

## `--exec`

Instead of a config, a single shell command can fill the bar. It runs every
`--interval` seconds, and each output line fills one bar row. A line may hold
two tab-separated slots: `left` or `left<TAB>right`. Markup, raw SGR colors
and OSC 8 hyperlinks are kept; cursor movement is stripped.

    statusbar -i 5 -s '' -e 'printf " #[bold]%s#[default]\t%s \n" "$(hostname -s)" "$(date +%H:%M)"'

## How it works

- The outer terminal's scrolling region (DECSTBM) covers only the child's
  rows, so ordinary output and scrolling never reach the bar.
- Output is scanned for sequences that address absolute rows (CUP, HVP,
  VPA, DECSTBM). They are clamped to the child's rows and, for a top bar,
  shifted down. Erasures that reach the bar, RIS, DECSTR, DECALN and
  alternate-screen switches trigger a repaint.
- Replies from the terminal (cursor position reports, XTWINOPS 18, SGR and
  X10 mouse events) are translated back; mouse clicks on the bar are
  dropped.

## Limitations

- Repaints use DECSC/DECRC, the same single save slot the child uses. They
  only happen between complete sequences, after the child's output has
  paused for 30ms, so collisions are unlikely but possible.
- Terminals only save lines to scrollback when the scrolling region starts
  at row 1. That's why the bar defaults to the bottom; with `-p top`, output
  that scrolls off inside the session may not reach scrollback.
- With the bar at the bottom, erase-below (`CSI J`) also erases the bar, so
  it is repainted more often than at the top.
- When the window grows, terminals that add blank rows at the bottom (rather
  than pulling lines back from scrollback) can leave a copy of the old bar
  in the child's area until it is overwritten.
