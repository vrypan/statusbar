# Add and remove temporary rows

Use `statusbar push` when a command needs its own row without reserving a
numbered slot in your config:

```sh
tail -n 0 -f app.log | statusbar push &
```

The row appears below configured rows. Its left slot shows a session-local ID;
the right slot shows the latest stream value:

```text
[1]                         Starting…
[1]                       Server ready
```

When reading a pipe, `push` cannot change the width reported to the command
that wrote to it. Output wider than the space beside the ID is clipped.

To let a width-aware command draw for the space beside the ID, start it with
`push --`:

```sh
statusbar push -- curl --progress-bar --limit-rate 1M \
  -o /dev/null https://proof.ovh.net/files/100Mb.dat &
```

`push` sets the command's `COLUMNS` to the terminal width minus the `[ID] `
prefix. It captures both stdout and stderr, so curl's progress output reaches
the row. The width is measured when the command starts; resizing the terminal
does not change the running command's `COLUMNS`. The command's exit status is
returned by `push` after it prints the row ID. Output files should be specified
for commands whose stdout is data rather than status text.

`push` reads a pipe or file. It displays the latest line as it arrives,
including partial lines and `\r` progress updates. Short input bursts are
combined; updates are sent at most every 50 ms, plus a final update at EOF.
Identical redraws are skipped. Each line is limited to 1024 bytes without
splitting a UTF-8 character. Stream text is literal: `##` and `#[bold]`
display as written. ANSI colors and hyperlinks work, while cursor movement
and backspace editing are not interpreted. The final value remains on screen
when input ends. At EOF, `push` prints the ID to stdout and exits:

```sh
id=$(printf 'Build complete\n' | statusbar push)
# The row is still visible.
statusbar pop "$id"
```

For a background pipeline, use the ID shown on the bar to remove its row:

```sh
statusbar pop 1
```

`pop` can remove any pushed row by ID, even while its input is still flowing.
The producer keeps running and future updates to that removed row are ignored.
Removing the same ID again succeeds. IDs are never reused during a session.
`pop` cannot remove a configured row. Up to 128 pushed rows may exist at once.

Pushed rows survive a replacement of the running config. They do not add
numbered slots, and `statusbar config --print current` prints only config text.
As with configured rows, rows that do not fit a short terminal remain stored
and reappear when there is room. A push may therefore succeed while its row is
hidden.

If `push` loses its input or exits unexpectedly, the last value accepted by
the running bar stays visible; its ID remains in the row prefix. Neither `push`
nor `pop` works outside a live statusbar session. A missing, stale, or
incompatible session is reported as an error.
