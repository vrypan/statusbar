# Named FIFOs

Create a named pipe inside a running statusbar session to send output directly
to a configured slot or to a new pushed row:

```sh
statusbar fifo --slot 3 prompt
printf 'Ready\n' > "$STATUSBAR_SLOTS/prompt"

statusbar fifo build
make > "$STATUSBAR_SLOTS/build" 2>&1
```

`statusbar fifo [--slot N] NAME` prints the absolute FIFO path after the
session has created it. A command can save the path with
`build_fifo=$(statusbar fifo build)`. `STATUSBAR_SLOTS` is unique to the
session, but the directory and pipe do not exist until the first `fifo`
request. Create the pipe before using shell redirection: opening a missing
path for output can create a regular file instead.

Without `--slot`, the command creates a pushed row tagged `NAME`. With
`--slot N`, it binds to an existing configured slot, including one currently
hidden by a small terminal. Names are 1–64 ASCII characters: a letter or
underscore followed by letters, digits, underscores, periods, or hyphens.
Creating the same name and target again returns the same path and keeps its
text. A name cannot change targets, and each configured slot can have only
one FIFO.

The latest nonempty line is displayed. Carriage returns work for progress
updates, and a final partial line appears after a short pause. Separate writes
without a newline join into one line; end each independent update with `\n`.
Closing a writer leaves the last value visible. Pushed FIFO rows stay in their
running state until you finish or remove them. Multiple writers share one byte
stream, so their output can interleave.

To give a pushed FIFO row the same completion style as a command started with
`push --`, report the producer's exit code after it closes the pipe:

```sh
statusbar fifo build
make > "$STATUSBAR_SLOTS/build" 2>&1
result=$?
statusbar fifo --finish build --exit-code "$result"
```

`--exit-code 0` selects `[line.push.success]`; a nonzero code selects
`[line.push.failed]`. `statusbar fifo --finish build` selects
`[line.push.done]` without an exit code. The last output remains visible.
The session reads pending FIFO output before marking the row complete.
Later writes do not change a completed row. To reuse the same pipe, run
`statusbar fifo --start build` before the next producer; this clears the old
text and returns the row to its running state. Stop old writers before
finishing or restarting the row. These options apply only to pushed-row FIFOs,
not to `--slot` bindings. The commands use the session's authenticated Unix
datagram socket; state markers are never part of FIFO output.

An ordinary `statusbar set` may replace a slot's displayed value. The next
FIFO input takes precedence again. Removing a slot FIFO restores the configured
value:

```sh
statusbar fifo --remove prompt
statusbar fifo --remove build
```

Removal prints nothing and succeeds if the name is already absent.
`statusbar pop ID`, bare `pop`, and `pop --all` also remove pushed FIFO bindings, while
leaving configured-slot bindings intact. Bindings survive compatible config
reloads and terminal resizes. A reload that removes a configured slot removes
its FIFO. The session removes its pipes at normal shutdown.

Existing writers to a removed pipe may get `EPIPE` or `SIGPIPE`. Recreating a
name creates a new pipe; an old open writer cannot send data to that new
binding. FIFO creation and removal require a live statusbar session. The
session uses its authenticated local control socket for those operations;
ordinary writes use the pipe's filesystem permissions.
