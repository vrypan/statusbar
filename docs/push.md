# Add and remove temporary lines

Use `statusbar push` when a command needs its own line. For a quick example,
send it a line of text:

```sh
printf 'Build complete\n' | statusbar push -t build
```

The line appears below your configured lines. `push` prints its ID when input
ends; the line stays visible until you remove it with `statusbar pop`. To watch
a log, keep the pipeline running in the background:

```sh
tail -n 0 -f app.log | statusbar push -t app.log &
```

By default, the line shows its ID, optional tag, and latest line on the left:

```text
[1] app.log > Server ready
```

Use `-t TEXT` or `--tag TEXT` to label a line. For a background pipeline, read
the ID on statusbar and run `statusbar pop ID` to remove that line. Without an ID,
`statusbar pop` removes the newest line.

A script can save the returned ID to remove its own line later:

```sh
id=$(printf 'Build complete\n' | statusbar push -t build)
statusbar pop "$id"
```

Tags must be plain UTF-8 text without control characters and may contain up
to 128 bytes. A theme can place the tag and ID in either slot.

Set the base style of pushed lines with `[line.push]` in the config. Use its
`left` template with `#(stream)`, `#(tag)`, and `#(id)` to format the line;
the `right` template can place values on the other side. Templates are
reapplied to each `\r` progress update. See
[configuration](config.md#linepush).

When reading a pipe, `push` cannot change the width reported to the command
that wrote to it. Output wider than the space left for the stream is clipped.

To let a width-aware command draw for the stream's available space, start it with
`push --`:

```sh
statusbar push -t 100Mb.dat -- curl --progress-bar --limit-rate 1M \
  -o /dev/null https://proof.ovh.net/files/100Mb.dat &
```

`push` sets the command's `COLUMNS` to the space available for the stream. It
captures both stdout and stderr, so curl's progress output reaches the line.
The width is measured when the command starts; resizing the terminal does not
change the running command's `COLUMNS`. `push` returns the command's exit
status after printing the line ID. Specify an output file for commands whose
stdout contains data you want to save.

`push` reads a pipe or file. It displays the latest line as it arrives,
including partial lines and `\r` progress updates. Short input bursts are
combined; updates are sent at most every 50 ms, plus a final update at EOF.
Identical redraws are skipped. Each line is limited to 1024 bytes without
splitting a UTF-8 character. Stream text is literal: `##` and `#[bold]`
display as written. ANSI colors and hyperlinks work, while cursor movement
and backspace editing are not interpreted. The final value remains on screen
when input ends. At EOF, `push` prints the ID to stdout and exits.

`pop` can remove any pushed line by ID, even while its input is still flowing.
The producer keeps running and future updates to that removed line are ignored.
Removing the same ID again succeeds. IDs are never reused during a session.
`pop` cannot remove a configured line. Up to 128 pushed lines may exist at once.
`statusbar pop` reports an error when there are no pushed lines to remove.

Pushed lines survive a replacement of the running config. They do not add
numbered slots, and `statusbar config --print current` prints only config text.
As with configured lines, lines that do not fit a short terminal remain stored
and reappear when there is room. A push may therefore succeed while its line is
hidden.

If `push` loses its input or exits unexpectedly, the last value accepted by
the running statusbar stays visible; its ID remains on the line. Neither `push`
nor `pop` works outside a live statusbar session. A missing, stale, or
incompatible session is reported as an error.
