# Display and animation model

statusbar draws into a terminal emulator, but it does not control the
terminal's display refresh rate. It sends terminal output; the emulator decides
when that output becomes pixels. To avoid confusing those two layers, this
document uses *content update*, *animation tick*, *frame*, and *paint* instead
of the overloaded word *refresh*.

## Terms

**Content update** is accepted source data, such as command output, a clock
change, or a numbered-slot update. A semantic change to that data changes the
statusbar's base content. An effect may start only when that source is eligible
to trigger one. Currently, configured `#[track]...#[notrack]` regions can
highlight changes from command output and template clocks. Manual slot values
and `--exec` output cannot define tracking regions.

**Animation tick** samples all active effects at one monotonic timestamp.
Effects never paint independently.

**Frame** is one complete desired statusbar appearance after applying every
active effect to the current base content. A frame exists in memory as styled
grapheme cells; it is not terminal output.

**Paint** is one bundled terminal write that makes the displayed statusbar
match a frame. A paint may contain several changed rows and regions. If the new
frame is visually identical to the last painted frame, no paint is needed.

**Terminal display refresh** is the terminal emulator turning its state into
pixels. Its timing is outside statusbar's control and is not part of this model.

The central relationship is:

```text
content updates + one animation tick
                 │
                 ▼
        compose one complete frame
                 │
                 ▼
          zero or one paint
```

One paint can therefore include changes from many content sources and effects.
One temporary or animated effect usually spans several frames and paints.

## Three stored appearances

Each visible row has three related states:

1. **Base** is the latest laid-out content without temporary effects.
2. **Desired** is the frame produced by applying active effects to the base.
3. **Painted** is the last frame committed after statusbar prepared its
   terminal write. It records terminal state, not pixels the terminal emulator
   has displayed.

Content updates replace relevant parts of the base. Animation ticks derive or
update the desired appearance from the current base and effect state. Painting
compares desired with painted, emits only necessary rows, then advances the
painted snapshot.

Effects modify appearance, never the base. When an effect expires, composing
from the base naturally restores the exact current foreground, background,
attributes, and hyperlinks. It does not restore a stale copy captured when the
effect began.

The renderer also retains the reason for rebuilding the base. A content update
and a layout rebuild can produce similar cell differences, but they are not the
same event. Only a semantic content update is allowed to create or restart an
effect.

## Effect triggers

Effects are consequences of content transitions, not rendering differences.
An effect may start only while processing an eligible content update and only
when the tracked content changed semantically.

A region has a stable identity within its configured row and left/right slot.
Its width and position may change without changing that identity. Comparison
uses its full styled grapheme content before clipping, plus a visible-content
check with both versions projected into the same final available space.
Changes confined to a hidden suffix do not flash an unchanged visible prefix.
Each changed region restarts only its own effect.

All commands in a slot must have accepted a first result before its regions
can trigger effects. Empty results count. Overrides cancel that slot's effects;
clearing an override establishes new baselines silently. Empty and wholly hidden
regions carry no animation backlog, and newly revealed rows baseline silently.

These events never create or restart an effect:

- resizing the terminal;
- reflowing or clipping an existing value;
- a row becoming hidden or visible;
- rebuilding cells after a style or layout change;
- repainting after screen damage;
- composing an animation frame; or
- painting a frame.

This requires explicit event provenance. The renderer must not infer an effect
trigger merely because newly laid-out cells differ from the previous grid. A
resize can move a region, expose more of it, or clip it differently without its
source value changing.

An effect that was already active before a resize may continue from its
original start time. Reapplying its current appearance to the resized grid is
continuation, not a new trigger: its start time and deadline do not change. An
implementation may instead cancel an effect whose target disappears, but it
must not restart it when that target later becomes visible.

Commands rerun after a resize can legitimately produce different width-aware
text. Those results carry a geometry origin and establish a new baseline
silently. A normal interval result that was already running when the resize
arrived retains its normal origin; it remains eligible as an ordinary content
update. This distinction follows each command run until its result is accepted.

## One shared frame scheduler

Every effect records logical state such as its target, start time, duration,
and colors. It does not own a rendering timer or write terminal output. A
single scheduler finds the next time at which any active effect can produce a
different frame.

When that time arrives, statusbar:

1. drains all ready input and content updates;
2. samples every active effect using the same `now` value;
3. composes one complete desired frame;
4. compares it with the painted frame; and
5. requests one paint if anything visible changed.

This makes simultaneous effects coherent. Two values changing close together
can appear in the same frame and terminal write rather than racing through
separate redraws.

Sampling, composition, and painting can advance or finish existing effects;
none of them can activate an effect. Activation belongs exclusively to the
content-update path.

The scheduler is demand-driven. With no active effects or content changes,
there is no animation tick and no idle rendering work. Discrete effects, such
as the configured highlight color sequence, schedule their next color step.
The adaptive color pulse samples a smooth curve every 30 ms while it is active.
Its color range is checked before playback and cached per resolved color pair
and pulse count. Frame sampling does not independently adjust contrast limits:
that would introduce brightness jumps into an otherwise smooth curve. Repeated
pulses stay within the animated range between peaks and restore the base only
at the end of the complete effect.
Palette discovery can update color resolution without starting or restarting
an effect; every sample still derives from the current base colors.
The cadence is an implementation policy, not a terminal refresh rate.

Starting an effect makes its first appearance eligible immediately. Later
steps can align to the shared scheduler. If terminal safety delays a paint,
statusbar samples effects at the current time and skips obsolete intermediate
frames instead of replaying them in a burst.

## Effects and frames

An effect is a function of base cells and time:

```text
desired cells = effect(base cells, now)
```

A static appearance change may need only one frame. A temporary highlight
needs at least one highlighted frame and a later restored frame. A twelve-color
highlight can produce twelve colored frames followed by a restored frame:

```text
content update starts highlight
    ├── frame 1  → paint color 1
    ├── frame 2  → paint color 2
    ├── ...
    ├── frame 12 → paint color 12
    └── frame 13 → paint restored base
```

Each frame includes all effects active at that time:

```text
base content ───────────────┐
highlight region A ─────────┤
highlight region B ─────────┼─→ one desired frame → one paint at most
future focus/selection ──────┘
```

When effects can overlap, composition must have a documented, deterministic
order. Effects should remain independent state transformations even when the
renderer applies them as an ordered stack. Adding one effect must not make it
responsible for scheduling or painting another.

## Event behavior

| Event | Change base? | May trigger effect? | Painting behavior |
|---|---:|---:|---|
| Semantic source change | Yes | Only if its source is eligible | Paint changed visible rows |
| Identical content result | No | No | No paint |
| Animation tick | No | No | Paint only if appearance changed |
| Screen damage | No | No | Repaint all visible rows |
| Resize or layout change | Re-layout | No | Repaint the visible bar |
| Row becomes hidden or visible | Re-layout | No | Paint visible rows as needed |

Several events handled in one event-loop iteration still produce one composed
frame. A content update can restart one effect while unrelated effects retain
their own start times and durations. Layout and paint events cannot restart
either one.

## Paint safety and coalescing

Painting the bar temporarily uses terminal cursor and mode state. statusbar
therefore paints only at a safe child-output boundary and may wait briefly
while the child owns the cursor-save slot. This safety delay does not create a
queue of frames: only the newest desired frame matters.

All changed rows for a frame are serialized into one output batch. The renderer
may compose the entire visible statusbar in memory while emitting only rows
whose desired cells differ from their painted cells. A frame opportunity does
not imply a terminal write.

This separation gives the model its main invariant:

> Content sources and effects update state independently; the renderer composes
> one coherent frame; terminal output is coalesced and selective. Only semantic
> content changes trigger effects.

## Consequences for future features

The model supports change highlights, focus, selection, fades, and similar
effects without giving each feature its own redraw path. A new effect needs:

- a stable target, such as a tracked region;
- logical timing and appearance state;
- a deterministic place in effect composition; and
- a way to report when its next visible state can change.

It does not need direct access to the terminal writer. This keeps animation
policy separate from Unicode layout, change detection, damage repair, and
terminal safety.
