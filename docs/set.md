# Set the text of a slot

Each configured row has two numbered slots:

| Row | Left | Right |
|-----|------|-------|
| 1   | 1    | 2     |
| 2   | 3    | 4     |
| 3   | 5    | 6     |

The pattern continues: row *N* uses slots *2N − 1* and *2N*.

`statusbar set SLOT [TEXT...]` sets the text of a slot. With no text, or a value made
only of CR/LF line breaks, it restores the configured value:

```sh
statusbar set 3 "$(git branch --show-current)"
statusbar set 4 "build ✓"
statusbar set 4
```

Slots exist for every desired row, including rows temporarily hidden because
the terminal is short. Updating a hidden slot persists and appears when its
row becomes visible. A slot outside the session's configured range is an
error and never creates another row. Validation uses the session's current
config after an interactive replacement, not its startup row count.

Words are joined with spaces. Tabs and interior line breaks become spaces,
while quoted spaces—including an all-space value—are preserved as padding.
Values are limited to 1024 bytes. Markup and raw SGR colors work in values.
Outside a statusbar session, a syntactically valid command writes nothing and
exits successfully, so shell hooks can call it unconditionally.

## Stream the latest line

Use a sole `-` argument to read stdin continuously:

```sh
tail -n 0 -f app.log | statusbar set 4 -
(tail -n 0 -f app.log | statusbar set 4 -) &
```

The slot updates while a line is arriving; it does not wait for a newline.
Carriage returns and newlines start a new line. The previous value stays visible
until the next line supplies text, and the final value stays after EOF. Fast
intermediate lines can be skipped: statusbar sends at most one update every
50 ms, plus a final update at EOF. It waits briefly for nearby fragments of a
progress report to arrive together. A producer that pauses in the middle of a
report for longer than this window can still display a partial line. The first
1024 bytes of each line are kept,
without splitting a UTF-8 character; the rest is ignored until the next line.
When a producer redraws the same line with `\r`, the identical value is not
sent again.
Streamed `#` and `#[...]` display literally, preserving progress bars and log
text. Supported ANSI colors and hyperlinks still work. One-shot TEXT retains
statusbar markup. Streaming shows the latest line; cursor movement and
backspace editing are not interpreted.

Curl sends its progress bar to stderr. Save the download separately and pipe
the progress to a slot:

```sh
(curl --progress-bar -o download.zip https://example.com/download.zip 2>&1 |
  statusbar set 4 -) &
```

`statusbar set 4` still restores the configured value. To display a literal
dash, use `statusbar set 4 -- -`. Streaming requires a pipe or redirected file;
terminal stdin is rejected. It returns immediately outside a statusbar session.
If another sender updates the same slot, the latest update wins. A later config
change can remove the slot, in which case the stream continues but its updates
are ignored by the bar.

The command writes to `/dev/tty`, not stdout, so it also works from tools that
capture command output:

```toml
[custom.statusbar]
command = "statusbar set 4 \"$(git branch --show-current)\""
when = true
```

## The escape sequence

The one-based slot number is part of an iTerm2-style user variable:

```
ESC ] 1337 ; SetUserVar=StatusBarSlotN=<base64> BEL
```

ST (`ESC \\`) also terminates it. For example:

```sh
printf '\e]1337;SetUserVar=StatusBarSlot4=%s\a' "$(printf %s 'build ✓' | base64 | tr -d '\n')"
```

Streamed updates use `StatusBarSlotLiteralN` in the same OSC envelope. The
receiver uses the name to bypass statusbar markup for that value; existing
`StatusBarSlotN` senders keep their markup behavior.

statusbar consumes valid numbered slot variables and drops malformed or
out-of-range variables under its `StatusBar` namespace. It forwards unrelated
OSC sequences and user variables to the terminal. Updates are one-way and
have no acknowledgement.
