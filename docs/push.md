# Add and remove temporary lines

`statusbar new build` creates an empty line and prints its name immediately
when stdin is a terminal. Update it later with `statusbar update`:

```sh
statusbar new build --status normal
statusbar update build "Compiling…" --status running
```

Use `statusbar new` when a command needs its own line. For a quick example,
send it a line of text:

```sh
printf 'Build complete\n' | statusbar new build
```

The line appears below your configured lines. `new` prints its name when
input ends; the line stays visible until you remove it with `statusbar remove`.
It skips the terminal print when running in the background, so the shell does
not suspend the job on terminals with `tostop` enabled. Redirected stdout
still receives the name.
To watch a log, keep the pipeline running in the background:

```sh
tail -n 0 -f app.log | statusbar new applog &
```

With the built-in config, the line shows a status indicator, its name, its
latest value and a dotted fill.

## Run a command in the background with `+`

The Zsh and Fish [shell integrations](usage.md#background-shortcut) define
this shortcut inside statusbar sessions:

```sh
+ make test
+ +build make test
```

The first generates a name such as `make-5`; the second uses `build`. Both
return to your prompt immediately and leave the line showing the command's result.
Remove it with `statusbar remove NAME`. Explicit names must be unique;
generated names let you run the same command concurrently. Add `--no-plus`
to your `statusbar init` command to opt out.
An existing `+` function or alias is preserved.

## Names and IDs

NAME is optional. Without it, `new` generates a name such as `tmp-5` and
prints that name. Use `--prefix download` (or `-p download`) to generate
`download-ID` instead. Prefixes use 1–43 letters, digits, `_` or `-`.
An explicit NAME takes precedence over `--prefix`.

Explicit names follow the [configured-line naming rules](config.md#linename):
1–64 letters, digits, `_`, `-` or dots between nonempty segments. Names and
group prefixes cannot be only digits, and a standalone line cannot share a
name with a group prefix. Names must be unique among all lines.

IDs are assigned by statusbar, increase through the session, and are never
reused. `#(name)` shows the explicit or generated name. A decimal target to
`update`, `bind`, or `remove` means an ID. For removal, the ID of a dotted
line selects its whole group; see [removing lines](#remove-lines).
A script can save the printed name:

```sh
name=$(printf 'Build complete\n' | statusbar new)
statusbar remove "$name"
```

## Commands

To let a width-aware command draw for the space available to its value,
start it with `new --`:

```sh
statusbar new download -- curl --progress-bar --limit-rate 1M \
  -o /dev/null https://proof.ovh.net/files/100Mb.dat &
```

`new` sets the command's `COLUMNS` to the space the line's template leaves
for its value. It captures both stdout and stderr, so curl's progress output
reaches the line. The width is measured when the command starts; resizing the
terminal does not change the running command's `COLUMNS`. `new` prints the
name at the end and exits with the command's status (128 + the signal number
if it was killed). Specify an output file for commands whose stdout contains
data you want to save.

A background command receives `/dev/null` for stdin when it would otherwise
inherit the terminal. This lets programs such as ffmpeg run without trying to
read or change the shell's terminal. Piped or redirected input is preserved,
and foreground commands keep their terminal input.

When reading a pipe, `new` cannot change the width reported to the command
that wrote to it. Output wider than the space left is clipped.

## Status

Temporary lines start with status `running`, or the status supplied with
`--status STATE`: `normal`, `running`, `done`, `success`, or `failed`. This
works for empty lines, stdin, commands, and FIFOs. Empty lines and FIFOs keep
that status until you change it. For example:

```sh
statusbar new build --status normal -- make
statusbar new progress --fifo --status running
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

The final text stays in `#(value)`. `statusbar update NAME --status STATE`
changes the status of a temporary line too, and any change is allowed. To show
activity while a command is quiet, add a [spinner](config.md#spinner). A
complete example is in [samples/spinner.statusbar](../samples/spinner.statusbar).
See [`[push]`](config.md#push) for all settings.

## Input

`new` reads a pipe or file. It displays the latest line as it arrives,
including partial lines and `\r` progress updates. Short input bursts are
combined; updates are sent at most every 50 ms, plus a final update at EOF.
Identical redraws are skipped. Each line is limited to 1024 bytes without
splitting a UTF-8 character. Stream text is literal: `##`, `#(value)` and
`#[bold]` display as written. ANSI colors and hyperlinks work, while cursor
movement and backspace editing are not interpreted. The final value remains
on screen when input ends.

For programs that write to a path, or several runs that should share one
line, use a FIFO: `statusbar new build --fifo` creates the line and a named
pipe together and prints the pipe's path. See [FIFOs](bind.md).

## Remove lines

To remove the newest temporary line, use `statusbar remove` with no argument.
It reports an error when there is none. To remove all temporary lines:

```sh
statusbar remove --all
# Short form: statusbar rm -a
```

`--all` succeeds even when there are no temporary lines. It cannot be combined
with a target. Up to 128 temporary lines may exist at once.

A target changes the scope: `statusbar remove build` removes a standalone
`build` line, or the entire `build.*` group, including configured lines,
commands, colors and temporary lines. It rejects a name containing dots.
A numeric ID selects a standalone line or its whole first-segment group:
removing the ID of `build.progress` removes the whole `build.*` group.
A standalone line and a group cannot share the same name.

Removing a line also removes its FIFO. Group removal stops removed configured
commands and rejects edits that leave unresolved dependencies or no configured
line. See [configuration removal](config.md#remove-a-prefix).

A producer keeps running after its line is removed, and its later output is
ignored, even if a new line takes the same name: each line belongs to the
`new` that created it, and a finished or removed producer can no longer
change any line.

Temporary lines survive a replacement of the running config, keeping their
values and statuses; the new `[push]` templates apply. `statusbar config
show current` prints only config text. As with configured lines, lines
that do not fit a short terminal remain stored and reappear when there is
room, so `new` may succeed while its line is hidden.

If `new` loses its input or exits unexpectedly, the last value accepted by
the running statusbar stays visible. Neither `new` nor `remove` works outside a
live statusbar session. A missing, stale, or incompatible session is reported
as an error.
