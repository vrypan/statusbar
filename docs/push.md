# Add and remove temporary lines

`statusbar push build` creates an empty line and prints its name immediately
when stdin is a terminal. Update it later with `statusbar set`:

```sh
statusbar push build --status normal
statusbar set build "Compiling…" --status running
```

Use `statusbar push` when a command needs its own line. For a quick example,
send it a line of text:

```sh
printf 'Build complete\n' | statusbar push build
```

The line appears below your configured lines. `push` prints its name when
input ends; the line stays visible until you remove it with `statusbar pop`.
To watch a log, keep the pipeline running in the background:

```sh
tail -n 0 -f app.log | statusbar push applog &
```

With the built-in config, the line shows its latest text on the left and its
name on the right:

```text
Server ready                                                         [applog]
```

## Names and IDs

NAME is optional. Names follow the same rules as configured lines: letters,
digits, `_` and `-`, not only digits, and unique among all lines. Without a
name, `push` prints the line's numeric ID, such as `5`, and `#(name)` shows
it. IDs are assigned by statusbar, increase through the session, and are never
reused. A decimal target always means an ID, so `statusbar pop 5` removes the
line with ID 5 even if it has a name. A script can save the printed name:

```sh
name=$(printf 'Build complete\n' | statusbar push)
statusbar pop "$name"
```

## Commands

To let a width-aware command draw for the space available to its value,
start it with `push --`:

```sh
statusbar push download -- curl --progress-bar --limit-rate 1M \
  -o /dev/null https://proof.ovh.net/files/100Mb.dat &
```

`push` sets the command's `COLUMNS` to the space the line's template leaves
for its value. It captures both stdout and stderr, so curl's progress output
reaches the line. The width is measured when the command starts; resizing the
terminal does not change the running command's `COLUMNS`. `push` prints the
name at the end and exits with the command's status (128 + the signal number
if it was killed). Specify an output file for commands whose stdout contains
data you want to save.

When reading a pipe, `push` cannot change the width reported to the command
that wrote to it. Output wider than the space left is clipped.

## Status

Pushed lines start with status `running`, or the status supplied with
`--status STATE`: `normal`, `running`, `done`, `success`, or `failed`. This
works for empty lines, stdin, commands, and FIFOs. Empty lines and FIFOs keep
that status until you change it. For example:

```sh
statusbar push build --status normal -- make
statusbar push progress --fifo --status running
```

`--status` controls only the initial status. When input ends, a pipe or file
sets `done`; a command sets `success` for exit status 0 and `failed`
otherwise, including termination by a signal. Give each status its own look
in `[push]`:

```ini
[push]
text    = "#(spinner) #(value)#(fill: )[#(name)]"
done    = "· #(value)#(fill: )[#(name)]"
success = "#[fg=green]✓#[default] #(value)#(fill: )[#(name)]"
failed  = "#[fg=red]✗#[default] #(value)#(fill: )failed [#(name)]"
```

The final text stays in `#(value)`. `statusbar set NAME --status STATE`
changes the status of a pushed line too, and any change is allowed. To show
activity while a command is quiet, add a [spinner](config.md#spinner). A
complete example is in [samples/spinner.statusbar](../samples/spinner.statusbar).
See [`[push]`](config.md#push) for all settings.

## Input

`push` reads a pipe or file. It displays the latest line as it arrives,
including partial lines and `\r` progress updates. Short input bursts are
combined; updates are sent at most every 50 ms, plus a final update at EOF.
Identical redraws are skipped. Each line is limited to 1024 bytes without
splitting a UTF-8 character. Stream text is literal: `##`, `#(value)` and
`#[bold]` display as written. ANSI colors and hyperlinks work, while cursor
movement and backspace editing are not interpreted. The final value remains
on screen when input ends.

For programs that write to a path, or several runs that should share one
line, use a FIFO: `statusbar push build --fifo` creates the line and a named
pipe together and prints the pipe's path. See [FIFOs](bind.md).

## Remove lines

`statusbar pop NAME` removes a pushed line, by name or ID, even while its
input is still flowing. Without NAME, `statusbar pop` removes the newest
pushed line and reports an error when there is none. To remove every pushed
line at once:

```sh
statusbar pop --all
# Short form: statusbar pop -a
```

`--all` succeeds even when there are no pushed lines. It cannot be combined
with NAME. Removing a line also removes its FIFO. Configured lines cannot be
popped. Up to 128 pushed lines may exist at once.

A producer keeps running after its line is removed, and its later output is
ignored, even if a new line takes the same name: each line belongs to the
`push` that created it, and a finished or removed producer can no longer
change any line.

Pushed lines survive a replacement of the running config, keeping their
values and statuses; the new `[push]` templates apply. `statusbar config
--print current` prints only config text. As with configured lines, lines
that do not fit a short terminal remain stored and reappear when there is
room, so a push may succeed while its line is hidden.

If `push` loses its input or exits unexpectedly, the last value accepted by
the running statusbar stays visible. Neither `push` nor `pop` works outside a
live statusbar session. A missing, stale, or incompatible session is reported
as an error.
