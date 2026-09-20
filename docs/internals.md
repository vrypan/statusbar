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

The terminology and scheduling contract for content updates, effects, frames,
and terminal writes is described in the [display and animation
model](display-model.md).

Only the statusbar has a cell grid; the child's output remains a proxied byte
stream. Each visible row keeps three owned versions: base content, desired
appearance, and the last queued paint. Cells record graphemes, terminal width,
style, hyperlink, left/right/fill ownership, and optional tracking-region ID.
Wide graphemes also have a continuation cell, so clipping and appearance changes
cannot split them.

Ordinary updates rebuild only source rows whose bytes or region metadata
changed, compare their cells, and repaint only rows whose appearance changed. Identical updates emit
nothing. Startup, resize and screen damage repaint all visible rows. Damage
repair uses existing cells without parsing content again. Paints still use the
same safe output boundaries and cursor-save timing as before.

Internal slot, region, and column-range operations can patch and restore styles
without changing content. Patches survive unrelated-row updates, equivalent content
rebuilds, and damage repair. A semantic base change resets that row's patches;
resize rebuilds the grid. Each tracked region has a monotonic deadline
and applied-step index. The default effect is two adaptive color pulses over 2.4 seconds;
`[highlight]` can instead specify up to 16 background colors and either a
constant foreground or a matching foreground sequence. Each step is derived
from elapsed time, so delayed steps are skipped. Patches are reapplied after a
base rebuild or resize and restored on expiry; damage repair never restarts
the deadline.
Command results retain why their process ran. First results and reruns requested
by a terminal resize establish a new baseline silently; ordinary interval
results and clock changes may start a region highlight after every command used
in the slot has produced a first result. Step boundaries and expiry share one proxy
poll deadline and one composition pass. Within-row selective writes are not
implemented yet.

The adaptive effect samples OKLab lightness at 30 ms intervals. It derives
each pulse's phase from the absolute step modulo 40, without restarting the
effect deadline. Interior valleys stay at 45% of peak intensity, with smooth
joins; only the first rise and final fall reach the base. The relative-only
`pulses` setting accepts 1–3 repetitions. It derives foreground and background
from each base style, accounts for reverse video,
reduces chroma to remain in the sRGB gamut, and checks contrast after conversion.
The background moves toward the original foreground lightness (at most halfway),
while the foreground moves in the same direction to compensate. A smooth rise
and fall starts at the base colors with no initial dip. Peak OKLab lightness
adjustments are at most 0.20 for the background. The foreground sweeps toward
OKLab lightness 0.98 on dark backgrounds or 0.10 on light backgrounds, without
pulling already brighter/darker text inward. Each color pair's complete sampled
animation is checked to retain at least 75% of its original contrast and a
4.5:1 floor (or the original ratio when already below that floor). Background
movement is reduced first; foreground movement is reduced only if necessary.
This selects one range for the whole animation, not an independent correction
each frame. A bounded 16-entry cache keys ranges by resolved foreground,
background, and pulse count, so palette changes cannot reuse stale ranges.
Repeated adjacent styles reuse the same per-frame result. Both wide-glyph
cells get identical styles; the base is never modified. Unknown terminal
colors use a bold fallback, and expiry restores the original color tokens.

Startup sends read-only OSC 4/10/11 palette queries before the child is forked,
sharing the bounded cursor-query wait. A 128-byte streaming filter consumes
only valid replies to outstanding queries; keystrokes and unrelated, malformed,
duplicate, or oversized sequences pass through. A brief grace period accepts
late replies. The child's first OSC relinquishes all remaining query ownership
because OSC responses have no request IDs. Palette replies may recompose an
existing effect but never activate one. The palette is cached for the session.

Protocol reference: [xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html).
Color-space reference: [OKLab](https://bottosson.github.io/posts/oklab/).

Static template markers compile to ordinal boundaries. Source rows own raw-byte
spans; markup expansion and ANSI filtering map those boundaries into graphemes.
Each visible row also retains full semantic slot snapshots before clipping.
Regions compare glyph bytes, width, resolved style, and hyperlink values. Both
versions are projected into the target's final available column budget to
exclude changes in hidden suffixes and movement caused by neighboring values.
Override transitions carry per-slot epochs so identical-text activation/clearing
still cancels effects and establishes a silent baseline. Hidden rows discard
their snapshots and baseline silently when revealed.

### Unicode and styles

Grapheme segmentation and widths use the pinned remote zunic v0.5.0 dependency
(Unicode 17). Combining sequences, flags and joined emoji are kept whole. A
style, tracking-region, or OSC 8 hyperlink change inside a grapheme takes effect
at the next grapheme, never halfway through the current one. Standalone zero-width clusters
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
grids, full semantic snapshots, parsing scratch, staging and queued paint storage. An allocation or
budget failure ends the session through terminal cleanup rather than leaving
a partial snapshot as the last painted state. Established-capacity updates
reuse storage; preparation reserves space before emission and snapshot commit.

`zig build bench -Doptimize=ReleaseFast` measures full paints, identical updates,
single-row changes, style-only patches, and independent region updates with
shared animation frames and damage repair. It reports time, emitted bytes and
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
