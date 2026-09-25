# Usage

Start your usual shell with `statusbar`. Inside that session, these are the
commands most people need:

```sh
statusbar set 1 "Build passed"       # show text in a numbered slot
statusbar push -t build -- make       # give a command a temporary line
statusbar pop                         # remove the newest temporary line
statusbar pop --all                   # remove all temporary lines
statusbar config < another.config    # change the running layout
```

Run `statusbar --help` for the command list, or
`statusbar COMMAND --help` for a command's options. The full forms are:

```
statusbar [run] [options] [-- COMMAND...]
statusbar set <SLOT> [TEXT...]
statusbar push
statusbar push -- <COMMAND> [ARG...]
statusbar pop [ID | --all]
statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-slot N]
statusbar config [--print [default|startup|current]] [--default] [--path]
statusbar completion <bash|zsh|fish>
```

## `run`

Starts a shell or command with a status bar at the bottom of the terminal.
With no command, starts your usual shell (`$SHELL`). The session ends when
that shell exits.

`run` is the default command, so it can be left out:
`statusbar -- vim` is `statusbar run -- vim`. The command to run
always follows `--`.

| Option                  | Meaning                                                                 |
|-------------------------|-------------------------------------------------------------------------|
| `-c`, `--config PATH`   | config file, or `-` for stdin; see [config.md](config.md) for where it is looked for, and the built-in default |
| `--log PATH`           | append runtime diagnostics to a regular file |

Options take their value as the next argument (`--config my.config`) or
with `=` (`--config=my.config`). Use `--config -` to read from stdin.
The config defines the lines, commands, refresh intervals, and styles.

During a session, `cat FILE | statusbar config` or `statusbar config < FILE`
replaces the complete layout—including its line count—without restarting the
command. See [configuration](config.md#replace-the-running-config) for
replacement semantics.

## `set`

`statusbar set SLOT [TEXT...]` sets the text of a slot. Each line has a left
and right slot: line 1 uses slots 1 and 2, line 2 uses slots 3 and 4, and so on.
Omit the text to restore the value from your config:

```sh
statusbar set 1 'Build passed'
statusbar set 1
```

`statusbar set 4 -` displays a literal dash. Text supports statusbar markup;
see [set.md](set.md) for formatting and more examples. To stream the latest
line of output, use `statusbar push`.

## `push` and `pop`

`command | statusbar push` appends a line with a visible ID and streams the
latest line of input into it. When input ends, it prints the ID to stdout and
leaves the final result displayed. `statusbar pop` removes the newest pushed
line still present; `statusbar pop ID` removes a specific line, even if its
stream is still active. See [pushing lines](push.md) for examples and
limits. Pushed lines do not have numbered slots and survive config replacement.
`statusbar push -t label -- command` shows `[ID] label > stream` by default.
It starts the command with `COLUMNS` set to the width available for the stream,
streams its stdout and stderr, and returns its exit status.

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
slot is absent. Directory reporting works independently, even with one statusbar
line. Disabling both features prints nothing, as does running `init` outside a
statusbar session.

Reports are sent to the controlling terminal when the directory changes and
before each prompt. Repeating initialization does not duplicate these hooks.

## `config`

Choose which configuration to print:

| Option | Meaning |
|--------|---------|
| `--print default` | Built-in default config |
| `--print startup` | Exact config originally loaded by this session |
| `--print current` | Active config, including live replacements |
| `--print` | Same as `--print current` |
| `--default` | Alias for `--print default` |
| `--path` | File a new session would load, or `built-in` |

`startup` and `current` require a running session. They preserve the original
text, including comments, whitespace, and commands, without running those
commands. Temporary `statusbar set` overrides are excluded. The startup
snapshot also works for `--config -` and remains unchanged when its source
file is edited or removed. Nested sessions have separate snapshots.

`--path` uses `$STATUSBAR_CONFIG`, then `$XDG_CONFIG_HOME/statusbar/config`
(or `~/.config/statusbar/config` when `XDG_CONFIG_HOME` is unset). Use one
display option at a time; `--path` cannot be combined with `--print` or `--default`.

With no flags and terminal stdin, shows help. With piped or redirected stdin,
reads and validates the complete config until EOF, then sends its contents to
the current statusbar session. Empty input is an error. Printing flags ignore
stdin. Replacement prints nothing on success.

```sh
statusbar config --print current > saved.config
statusbar config --print startup | statusbar config
cat my.config | statusbar config
statusbar config < my.config
statusbar config --default | statusbar config
```

To start a config of your own from the built-in one:

```sh
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config
```

`--default` works outside a session and ignores existing config files.

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
printf '[line.1]\nright = %%H:%%M\n' | statusbar --config -

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
| `STATUSBAR_COLUMNS` | configured commands       | the statusbar width                      |
| `STATUSBAR_CONFIG`  | read by statusbar         | config file, when `--config` isn't given |
| `STATUSBAR_STATE`   | the child                  | session indicator and private current line count and config snapshots used by `set` and `config` |

## Logging

For session diagnostics, use `statusbar run --log /tmp/statusbar.log` (or omit
`run`). The file is opened before terminal mode starts; an invalid destination
is a startup error. New files have owner-only permissions; existing files are
appended to without changing their permissions. Parent directories must exist.
Records start with Unix time in milliseconds and cover session start/exit and
config replacement results. Config contents and terminal output are not logged.
Logging is capped at 32 records per second; excess records are dropped. A write
failure disables logging for the rest of that session without interrupting the
shell. Without `--log`, no diagnostic log is created.

## Config replacement details

`statusbar config < FILE` sends a replacement request to the running session.
The command can confirm that the request was sent, but the session checks it
separately. Invalid requests leave the current config in place. Configs sent
this way are limited to 24,523 bytes. If several programs load configs at
once, serialize their requests so their terminal writes do not interleave.
See [OSC config replacement](osc-3110.md) for the wire format.
