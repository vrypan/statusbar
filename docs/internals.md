# How it works

statusbar is a PTY proxy. It sits between the terminal and the command it
runs, and forwards both directions.

```
terminal emulator     the child's screen, and the bar below it
    |
statusbar             allocates a pty shorter by the visible bar rows
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
  leaves out the bar's rows, and mouse reports aimed at the bar are not sent
  to the child. Terminal UI actions such as opening an OSC 8 link still work.
- The bar is painted with autowrap off, so text that the terminal draws wider
  than statusbar measured is clipped at the right edge rather than wrapping.
- Numbered `StatusBarSlotN` user variables are taken out of the
  output stream; see [set.md](set.md).
- On a resize the child's pty follows the terminal. The visible row count is
  the smaller of the configured count and the terminal height minus two.
  Hidden rows retain their content and numbered-slot overrides.

## Rendering the bar

Only the statusbar has a cell grid; the child's output remains a proxied byte
stream. Each visible row keeps three owned versions: base content, desired
appearance, and the last queued paint. Cells record graphemes, terminal width,
style, hyperlink and left/right/fill ownership. Wide graphemes also have a
continuation cell, so clipping and appearance changes cannot split them.

Ordinary updates rebuild only source rows whose bytes changed, compare their
cells, and repaint only rows whose appearance changed. Identical updates emit
nothing. Startup, resize and screen damage repaint all visible rows. Damage
repair uses existing cells without parsing content again. Paints still use the
same safe output boundaries and cursor-save timing as before.

Internal slot and column-range operations can patch and restore styles without
changing content. Patches survive unrelated-row updates, equivalent content
rebuilds, and damage repair. A semantic base change resets that row's patches;
resize rebuilds the grid. Tracked commands use a separate monotonic deadline
and applied-step index per visible slot. The default effect is bold for 500 ms;
`[highlight]` can instead specify up to 16 background colors and either a
constant foreground or a matching foreground sequence. Each step is derived
from elapsed time, so delayed steps are skipped. Patches are reapplied after a
base rebuild or resize and restored on expiry; damage repair never restarts
the deadline.
Command results establish a first-result baseline, and subsequent changed
results are mapped through templates to slots and gated by semantic cell
changes. Step boundaries and expiry participate in the proxy poll timeout and
use the existing safe paint scheduler. Within-row selective writes are not
implemented yet.

### Unicode and styles

Grapheme segmentation and widths use the pinned remote zunic v0.5.0 dependency
(Unicode 17). Combining sequences, flags and joined emoji are kept whole. A
style or OSC 8 hyperlink change inside a grapheme takes effect at the next
grapheme, never halfway through the current one. Standalone zero-width clusters
are omitted; non-renderable clusters with a display width use a replacement
character. Widths account for text/emoji presentation: bare `▪` uses one
column, while `▪` followed by VS16 uses two. Supported variation bases followed
by VS15 request text presentation.

Styles are semantic values, not replayed escape strings. Supported attributes
include default/indexed/RGB foreground and background, underline color and
style, bold, dim, italic, blink, reverse, hidden, strikethrough and overline.
Unknown SGR attributes are ignored. Invalid escapes and unsafe hyperlinks are
filtered. Left, right and rule text have independent style/link state. Terminal
default colors remain defaults rather than being guessed as RGB values.

### Resource limits and measurement

Renderer-owned heap allocations share a 64 MiB budget, including all three
grids, parsing scratch, staging and queued paint storage. An allocation or
budget failure ends the session through terminal cleanup rather than leaving
a partial snapshot as the last painted state. Established-capacity updates
reuse storage; preparation reserves space before emission and snapshot commit.

`zig build bench -Doptimize=ReleaseFast` measures full paints, identical updates,
single-row changes and style-only patches. It reports time, emitted bytes and
rows, parsed rows and allocations. The cell model reduces terminal output for
small changes but costs memory and CPU compared with the old string renderer;
byte savings alone are not a wall-clock speedup.

## Limitations

- Repaints save and restore the cursor with DECSC/DECRC, the single save slot
  the child uses too. They only happen between complete sequences, and wait
  for a pause while the child holds a saved cursor, so collisions are
  unlikely but possible.
- When the window grows, terminals that add blank rows at the bottom (rather
  than pulling lines back from scrollback) can leave a copy of the old bar in
  the child's area until it is overwritten.
- Character widths are estimated using zunic's presentation-aware grapheme
  policy. A terminal using another Unicode
  version or width policy can still misalign the right slot.
