# How it works

statusbar is a PTY proxy. It sits between the terminal and the command it
runs, and forwards both directions.

```
terminal emulator     the child's screen, and the bar below it
    |
statusbar             allocates a pty 1 or 2 rows shorter than the terminal
    |
shell
```

- The outer terminal's scrolling region (DECSTBM) covers only the child's
  rows, so ordinary output and scrolling never reach the bar.
- The bar is always at the bottom. Terminals only save lines to scrollback
  when the scrolling region starts at row 1, so a bar at the top would lose
  everything that scrolls off inside the session.
- Output is scanned for sequences that address absolute rows (CUP, HVP, VPA,
  DECSTBM), and rows past the child's screen are clamped so they never reach
  the bar. Everything else passes through as it arrives.
- Erasures that reach the bar, RIS, DECSTR, DECALN and alternate-screen
  switches trigger a repaint. A repaint that follows an erasure goes out in
  the same write, so the terminal never shows a frame without the bar.
- Cursor position reports pass through unchanged, since the child's rows are
  numbered the same on both sides. The text-area size report (XTWINOPS 18)
  leaves out the bar's rows, and mouse clicks on the bar are dropped.
- The bar is painted with autowrap off, so text that the terminal draws wider
  than statusbar measured is clipped at the right edge rather than wrapping.
- `StatusBarLeft` and `StatusBarRight` user variables are taken out of the
  output stream; see [set.md](set.md).
- On a resize the child's pty follows the terminal, and the bar gives up its
  rows when the terminal is too short to spare them.

## Limitations

- Repaints save and restore the cursor with DECSC/DECRC, the single save slot
  the child uses too. They only happen between complete sequences, and wait
  for a pause while the child holds a saved cursor, so collisions are
  unlikely but possible.
- When the window grows, terminals that add blank rows at the bottom (rather
  than pulling lines back from scrollback) can leave a copy of the old bar in
  the child's area until it is overwritten.
- Character widths are estimated: East Asian wide characters, most emoji,
  and characters followed by VS16 count as two cells. A terminal that draws
  a symbol at another width can misalign the right slot.
