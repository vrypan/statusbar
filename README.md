# statusbar

A PTY proxy that keeps a one- or two-line status bar at the top of the
terminal and runs a shell (or any command) in a pty that is that much
shorter.

    zig build -Doptimize=ReleaseSafe
    ./zig-out/bin/statusbar -n 2 -i 5 \
        -e 'date "+%H:%M"; git -C ~/src/project branch --show-current'

The bar command runs under `/bin/sh -c` every `--interval` seconds. Each
output line fills one bar row, clipped to `STATUSBAR_COLUMNS`. SGR colors
and OSC 8 hyperlinks are kept; cursor movement is stripped.

## How it works

- The outer terminal's scrolling region (DECSTBM) starts below the bar, so
  ordinary output and scrolling never reach it.
- Output is scanned for sequences that address absolute rows (CUP, HVP,
  VPA, DECSTBM) and they are shifted down. Screen clears, RIS, DECSTR,
  DECALN and alternate-screen switches trigger a repaint.
- Replies from the terminal (cursor position reports, XTWINOPS 18, SGR and
  X10 mouse events) are shifted back up; mouse clicks on the bar are dropped.

## Limitations

- Repaints use DECSC/DECRC, the same single save slot the child uses. They
  only happen between complete sequences, after the child's output has
  paused for 30ms, so collisions are unlikely but possible.
- xterm, and terminals that follow it, only save lines to scrollback when
  the scrolling region starts at row 1. With the bar at the top, output that
  scrolls off inside the session may not reach the terminal's scrollback.
