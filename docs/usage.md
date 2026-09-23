# Usage

```
statusbar [run] [options] [-- COMMAND...]
statusbar set <SLOT> [TEXT...]
statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-slot N]
statusbar config [--print] [--path] [--default]
statusbar completion <bash|zsh|fish>
```

`statusbar --help` lists the commands, and `statusbar COMMAND --help` shows
each one's options.

## `run`

Starts a shell or command with a status bar at the bottom of the terminal.
With no command, starts your usual shell (`$SHELL`). The session
ends when the command exits, with the command's exit status. Background jobs
that still hold the terminal do not keep it open: output still arriving is
forwarded until it pauses, for at most half a second.

`run` is the default command, so it can be left out:
`statusbar -- vim` is `statusbar run -- vim`. The command to run
always follows `--`.

| Option                  | Meaning                                                                 |
|-------------------------|-------------------------------------------------------------------------|
| `-c`, `--config PATH`   | config file, or `-` for stdin; see [config.md](config.md) for where it is looked for, and the built-in default |
| `--log PATH`           | append runtime diagnostics to a regular file |

Options take their value as the next argument (`--config my.config`) or
with `=` (`--config=my.config`). Use `--config -` to read from stdin.
The config defines the rows, commands, refresh intervals, and styles.

For session diagnostics, use `statusbar run --log /tmp/statusbar.log` (or omit
`run`). The file is opened before terminal mode starts; an invalid destination
is a startup error. New files have owner-only permissions; existing files are
appended to without changing their permissions. Parent directories must exist.
Records start with Unix time in milliseconds and cover session start/exit and
config replacement results. Config contents and terminal output are not logged.
Logging is capped at 32 records per second; excess records are dropped. A write
failure disables logging for the rest of that session without interrupting the
shell. Without `--log`, no diagnostic log is created.

During a session, `cat FILE | statusbar config` or `statusbar config < FILE`
replaces the complete layout—including its row count—without restarting the
command. See [configuration](config.md#replace-the-running-config) for
replacement semantics.

## `set`

`statusbar set SLOT [TEXT...]` sets the text of a slot. Each row has a left
and right slot: row 1 uses slots 1 and 2, row 2 uses slots 3 and 4, and so on.
Omit the text to restore the value from your config:

```sh
statusbar set 1 'Build passed'
statusbar set 1
```

See [set.md](set.md) for formatting and more examples.

## `init`

`statusbar init zsh` or `statusbar init fish` prints shell integration that
reports the working directory with OSC 7 and moves Starship's prompt into
slot 3 when Starship is available. Both features default to `true`. Zsh
uses `eval "$(statusbar init zsh)"`; Fish uses `statusbar init fish | source`
after Starship's own initialization. Nushell can source
[the sample integration](../samples/statusbar.nu); see [starship.md](starship.md).

Use `--starship=false` for directory reporting alone, or `--report-cwd=false`
if another integration already reports directories. `--starship-slot N`
selects another slot; it cannot be combined with `--starship=false`. The hook
checks the live layout at every prompt, so it starts using the slot if a loaded
configuration adds it and leaves the full prompt in the terminal while the
slot is absent. Directory reporting works independently, even with one bar
row. Disabling both features prints nothing, as does running `init` outside a
statusbar session.

Reports are sent to the controlling terminal when the directory changes and
before each prompt. Repeating initialization does not duplicate these hooks.

## `config`

With `--print`, prints the configuration `run` would use: the config file, or the built-in
config when there is none. The config is parsed first, so this also checks
it: a broken file reports its error and exits with status 2.

| Option                | Meaning                                              |
|-----------------------|------------------------------------------------------|
| `--print`             | show the configuration a new session would load     |
| `--path`              | show the config file path, or `built-in`              |
| `--default`           | show the built-in default configuration              |

With no flags and terminal stdin, shows help. With piped or redirected stdin,
reads and validates the complete config until EOF, then sends its contents to
the current statusbar session. Empty input is an error. Printing flags ignore
stdin. No positional operands are accepted. Replacement prints nothing on
success. The request is one-way: success means it was written to the terminal,
while the running session still rejects invalid or unauthenticated requests
transactionally. Files transported this way are limited to 24,523 bytes. Large
concurrent writers should serialize requests because terminal writes are not an
interprocess message queue. The same validation and size limit apply to stdin.
See [OSC config replacement](osc-3110.md).

```sh
statusbar config --print > saved.config
cat my.config | statusbar config
statusbar config < my.config
statusbar config --default | statusbar config
```

To start a config of your own from the built-in one:

```sh
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config
```

Use `--default` here: the shell empties the target file before statusbar
reads it, so `statusbar config --print` would find an empty config.

## `completion`

`statusbar completion bash|zsh|fish` prints a completion script for the
commands, options and values:

```zsh
# Zsh: put this in ~/.zshrc before calling compinit.
mkdir -p ~/.zsh/completions
statusbar completion zsh > ~/.zsh/completions/_statusbar
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit
compinit
```

```sh
# Bash
mkdir -p ~/.local/share/bash-completion/completions
statusbar completion bash > ~/.local/share/bash-completion/completions/statusbar
```

```sh
# Fish
mkdir -p ~/.config/fish/completions
statusbar completion fish > ~/.config/fish/completions/statusbar.fish
```

## Generate a config on the fly

Use `--config -` to read a complete config from stdin:

```sh
generate-config | statusbar --config -

statusbar --config - <<'EOF'
interval = 5
style = fg=blue,bold

[line.1]
left = #(uptime)
right = %H:%M
EOF
```

statusbar reads up to 64 KiB and validates the config before starting the
session. The input must end (EOF); it is not a stream of ongoing updates.
After reading it, statusbar takes keyboard input from `/dev/tty`. A controlling
terminal is required, and stdout must still be a terminal. Empty or invalid
input is an error. To open a file literally named `-`, use `--config ./-`.

## Terminal title

When the child shell reports its working directory with OSC 7, statusbar
forwards that full report and sets a shortened terminal title from it, following
zsh's `%3~`: the local home directory becomes `~`, then only the last three
path components are shown. For example, `~/Devel/statusbar` stays as is, while
`~/Devel/statusbar/src` becomes `Devel/statusbar/src`. Remote reports retain the
host prefix, such as `server.example:/srv/project`, without substituting the
local home directory. Shell-specific named-directory aliases are not expanded.

`statusbar init zsh|fish` enables OSC 7 reporting by default. Other shell or
terminal integrations can also emit it; disable statusbar's reporter with
`--report-cwd=false` to avoid duplicates. Malformed,
unsupported and oversized reports are still forwarded but do not change the
derived title. A later title set by the child remains authoritative in normal
output order. OSC 7 currently affects only the title; it does not change the
working directory or environment of statusbar commands.

## Environment

| Variable            | Set for                   | Meaning                                  |
|---------------------|---------------------------|------------------------------------------|
| `STATUSBAR_LINES`   | the child and bar commands | desired rows at process start           |
| `STATUSBAR_COLUMNS` | bar commands              | the bar's width                          |
| `STATUSBAR_CONFIG`  | read by statusbar         | config file, when `--config` isn't given |
| `STATUSBAR_STATE`   | the child                  | private live row-count metadata used by `set` |
