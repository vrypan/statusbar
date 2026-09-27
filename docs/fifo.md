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
running state until removed. Multiple writers share one byte stream, so their
output can interleave.

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
