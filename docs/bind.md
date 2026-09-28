# FIFOs

A FIFO (named pipe) lets any program that writes to a file update a line.
Bind one to an existing line, configured or pushed, or create a pushed line
and its FIFO together:

```sh
prompt=$(statusbar bind prompt)
printf 'Ready\n' > "$prompt"

build=$(statusbar push build --fifo)
make > "$build" 2>&1
```

`statusbar bind NAME` and `statusbar push NAME --fifo` print the absolute
FIFO path, and nothing else, once the session has created it. The pipe lives
in `$STATUSBAR_FIFOS`, a private directory unique to the session, and is named
after the line: its name, or its numeric ID when it has none. An unnamed
`statusbar push --fifo` prints a path ending in its ID, so the basename
identifies the line:

```sh
fifo=$(statusbar push --fifo)
name=${fifo##*/}
printf 'Building\n' > "$fifo"
statusbar set "$name" --status running
statusbar pop "$name"
```

The directory and pipe do not exist until the first request. Create the pipe
before using shell redirection: opening a missing path for output can create a
regular file instead.

A line has at most one FIFO. Binding by ID or by name reaches the same one:
if the line with ID 5 is named `build`, `statusbar bind 5` and `statusbar bind
build` both print the path ending in `/build`. Binding again prints the same
path. Binding a configured line adds no row.

## Input

Text written to the pipe replaces the line's value; the latest nonempty line
is displayed. Carriage returns work for progress updates, and a final partial
line appears after a short pause. Separate writes without a newline join into
one line; end each independent update with `\n`. Multiple writers share one
byte stream, so their output can interleave. Values are literal, as with
`statusbar set`: `#(...)` and `#[...]` display as written, while ANSI colors
and OSC 8 links work.

Closing a writer leaves the last value visible and does not change the
status. Set the outcome yourself:

```sh
build=$(statusbar push build --fifo)
if make > "$build" 2>&1; then
  statusbar set build --status success
else
  statusbar set build --status failed
fi
```

Input already written to the pipe is applied before a following `statusbar
set`, so the final line and the status appear together. A line keeps
accepting input after any status change, so the same pipe can serve the next
run; set `--status running` when it starts. `statusbar set` can also replace
the value directly; the next FIFO input takes precedence again.

## Remove a FIFO

```sh
statusbar bind -u prompt
statusbar bind --unbind build
```

Removal prints nothing, keeps the line with its value and status, and
succeeds if the line has no FIFO. Removing a pushed line with `statusbar pop`,
including `pop --all`, also removes its FIFO. Bindings survive config reloads
that keep their line and terminal resizes. A reload that drops a configured
line removes its FIFO. The session removes its pipes at shutdown.

Existing writers to a removed pipe may get `EPIPE` or `SIGPIPE`. Binding
again creates a new pipe; an old open writer cannot send data to it. FIFO
creation and removal require a live statusbar session and use its
authenticated control socket; writes use the pipe's filesystem permissions.
A path that already exists and is not the session's pipe is never replaced.
