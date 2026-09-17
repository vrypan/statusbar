# statusbar

A PTY proxy that keeps a one- or two-line status bar at the bottom (or top,
with `-p top`) of the terminal and runs a shell (or any command) in a pty
that is that much shorter.

    zig build -Doptimize=ReleaseSafe
    ./zig-out/bin/statusbar -n 2 -i 5 \
        -e 'date "+%H:%M"; git -C ~/src/project branch --show-current'

The bar command runs under `/bin/sh -c` every `--interval` seconds. Each
output line fills one bar row. Raw SGR colors and OSC 8 hyperlinks are kept;
cursor movement is stripped.

## Slots

A line may hold up to three tab-separated slots, which statusbar aligns:

| Output                        | Layout                  |
|-------------------------------|-------------------------|
| `left`                        | left                    |
| `left<TAB>right`              | left, right             |
| `left<TAB>center<TAB>right`   | left, center, right     |

The center is centered on the whole line and moves aside for a long left or
right slot. When the line is too narrow, the center is dropped first, then
the right slot is clipped; the left slot is kept longest.

## Markup

Style text with tmux-like markup instead of escape codes:

    #[fg=#89b4fa,bold]host#[default] #[fg=brightblack]·#[default] 3.73

- `fg=` / `bg=`: `black` … `white`, `brightblack` … `brightwhite`,
  `colour214` (or `214`), `#rrggbb`, `default` (the terminal's own color)
- `bold dim italics underscore blink reverse strikethrough overline`, and
  `no…` to turn each off
- `default` or `none`: back to the bar's `--style`
- `##` is a literal `#`

Styles don't carry across slots.

## Example: two lines with a thin rule

Output line 1 is the bar's upper row, so a bottom bar puts the rule first:

```sh
#!/bin/sh
printf "#[fg=#45475a]%${STATUSBAR_COLUMNS}s\n" '' | sed 's/ /─/g'
printf ' #[fg=#89b4fa,bold]%s#[default] #[fg=#7f849c]·#[default] %s\t%s  #[bold]%s#[default] \n' \
  "$(hostname -s)" "$(sysctl -n vm.loadavg | awk '{print $2}')" \
  "$(date '+%a %d %b')" "$(date +%H:%M)"
```

    statusbar -n 2 -i 5 -s '' -e ~/bin/bar.sh

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
