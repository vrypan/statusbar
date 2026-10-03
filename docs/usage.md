# Usage

Start your usual shell with `statusbar`. Inside that session, these are the
commands most people need:

```sh
statusbar set build "Build passed"          # change a line's value
statusbar set build --status success        # or its status
statusbar push build -- make                # give a command a temporary line
statusbar pop                               # remove the newest temporary line
statusbar pop --all                         # remove all temporary lines
statusbar list --pushed                     # inspect temporary lines
statusbar config load another.statusbar     # change the running layout
statusbar config add extra.statusbar        # add new definitions
statusbar config remove extra               # remove extra.* definitions
```

Run `statusbar --help` for the command list, or
`statusbar COMMAND --help` for a command's options. The full forms are:

```
statusbar [run] [options] [-- COMMAND...]
statusbar set NAME [TEXT...] [--status STATE]
statusbar set NAME --reset [--status STATE]
statusbar push [NAME] [--status STATE]
statusbar push [NAME] [--status STATE] -- COMMAND [ARG...]
statusbar push [NAME] [--status STATE] --fifo
statusbar pop [NAME | --all]
statusbar list [--pushed] [--short] [--json]
statusbar bind [-u | --unbind] NAME
statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-line NAME]
statusbar config show [current|startup|default|path]
statusbar config check FILE
statusbar config load FILE
statusbar config add FILE
statusbar config list [--debug]     # alias: ls
statusbar config remove PREFIX     # alias: rm
statusbar config < FILE
statusbar completion <bash|zsh|fish>
```

NAME is a line's name, or its numeric ID. A decimal NAME always means an ID,
never a position in the bar.

Use [`statusbar list`](list.md) to inspect all lines, including hidden ones.
`--pushed` filters to temporary lines; `--json` returns a versioned snapshot
for scripts and integrations.

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

Options take their value as the next argument (`--config my.statusbar`) or
with `=` (`--config=my.statusbar`). Use `--config -` to read from stdin.
The config defines the lines, commands, refresh intervals, and styles.

If the config cannot be read or is invalid, `run` still starts the shell with
the built-in config and a line describing the problem; see
[where statusbar finds the config](config.md#where-statusbar-finds-the-config).

During a session, `cat FILE | statusbar config` or `statusbar config < FILE`
replaces the complete layout, including its lines, without restarting the
command. See [configuration](config.md#replace-the-running-config) for
replacement semantics.

## `set`

`statusbar set NAME` changes only what you supply: TEXT replaces the value,
`""` makes it empty, `--reset` restores the configured default, and
`--status` sets `normal`, `running`, `done`, `success` or `failed`:

```sh
statusbar set build 'Build passed' --status success
statusbar set build --status running
statusbar set build --reset
```

Values display literally; ANSI colors and OSC 8 links in them work.
`statusbar set build -` displays a literal dash. Outside a session, `set` does
nothing and succeeds. See [changing a line](set.md) for details and hooks.

## `push` and `pop`

`statusbar push [NAME]` with terminal stdin creates an empty line, prints
its name (or numeric ID), and returns. Use `set` to update it. In every mode,
`--status STATE` sets the initial status; the default is `running`.

`command | statusbar push [NAME]` appends a line and streams the latest line
of input into its value. When input ends, it sets the status to `done`, prints
the line's name (its numeric ID when unnamed) and leaves the final result
displayed. Background pushes skip that print when stdout is the terminal.
`statusbar push [NAME] -- command` starts the command with
`COLUMNS` set to the width available for the value, streams its stdout and
stderr, sets `success` or `failed` from its result, and returns its exit
status. `statusbar push [NAME] --fifo` creates the line with a FIFO and prints
the FIFO's path.

`statusbar pop` removes the newest pushed line still present; `statusbar pop
NAME` removes a specific line, even if its stream is still active. See
[pushing lines](push.md) for examples and limits. Pushed lines survive config
replacement.

## `bind`

`statusbar bind NAME` creates a FIFO for an existing configured or pushed line
and prints its path. Text written to it replaces the line's value.
`statusbar bind -u NAME` (or `--unbind`) removes the FIFO, keeping the line,
its value and its status. See [FIFOs](bind.md) for redirection, stream
behavior, and cleanup.

## `init`

`statusbar init zsh` or `statusbar init fish` prints shell integration that
reports the working directory with OSC 7 and moves Starship's prompt details
into the line named `prompt` when Starship is available. Both features default to `true`. Zsh
uses `eval "$(statusbar init zsh)"`; Fish uses `statusbar init fish | source`
after Starship's own initialization. Nushell can source
[the sample integration](../samples/statusbar.nu); see [starship.md](starship.md).

Use `--starship=false` for directory reporting alone, or `--report-cwd=false`
if another integration already reports directories. `--starship-line NAME`
selects another line; it cannot be combined with `--starship=false`. The hook
updates the line at every prompt, so it starts using the line if a loaded
configuration adds it and leaves the full prompt in the terminal while the
line is absent. Directory reporting works independently, even with one statusbar
line. Disabling both features prints nothing, as does running `init` outside a
statusbar session.

Reports are sent to the controlling terminal when the directory changes and
before each prompt. Repeating initialization does not duplicate these hooks.

## `config`

Create a personal config, check it, then load it inside a statusbar session:

```sh
mkdir -p ~/.config/statusbar
statusbar config show default > ~/.config/statusbar/config.statusbar
# Edit the file, then:
statusbar config check ~/.config/statusbar/config.statusbar
statusbar config load ~/.config/statusbar/config.statusbar
```

| Command | Meaning |
| --- | --- |
| `show [current]` | Print the active config, including live edits |
| `show startup` | Print the config originally loaded by this session |
| `show default` | Print the built-in config |
| `show path` | Show the config path selected for a new session, or `built-in` |
| `check FILE` | Validate a complete config without running its commands |
| `load FILE` | Replace the running layout |
| `add FILE` | Add new line, command and color definitions |
| `list` / `ls` | List current line and command definitions by prefix |
| `list --debug` | Show the whole parsed current config |
| `remove PREFIX` / `rm PREFIX` | Remove configured `PREFIX.*` definitions |

`FILE` is a filename, or `-` to read stdin. Bare `statusbar config` loads
redirected input and shows help when run directly in a terminal:

```sh
statusbar config load my.statusbar
statusbar config < my.statusbar
statusbar config show startup | statusbar config load -
statusbar config add extra.statusbar
statusbar config list
statusbar config remove extra
statusbar config show current > saved.statusbar
```

`check`, `show default`, and `show path` work outside a session. All other
operations require a running session. `show`, `list`, and `remove` ignore stdin.

`show current` and `show startup` preserve source text, including comments
and formatting, but exclude runtime values and statuses. The startup snapshot
stays unchanged after live edits or changes to its source file, including when
started with `--config -`. Nested sessions have separate snapshots.

`list` inspects current configuration definitions; `list --debug` includes
settings, colors, templates, defaults, commands, and push and highlight settings.
The debug output is not a reloadable config. Neither form runs commands.
Use [`statusbar list`](list.md) for live line values, statuses, and FIFO bindings.

`show path` checks `$STATUSBAR_CONFIG`, then
`$XDG_CONFIG_HOME/statusbar/config.statusbar` (normally
`~/.config/statusbar/config.statusbar`). It does not recover a running
session's `--config` argument or describe its current layout.

`add` rejects duplicate names and global settings. `remove` rejects edits
that leave dependencies unresolved or remove the last configured line.
Both preserve surviving line state and command processes; `load` restarts
configured commands. Live edits do not change the saved file. See
[configuration](config.md#add-to-the-running-config) for details.

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
printf '[line.clock]\ntext = "#(fill: )#(datetime:%%H:%%M)"\n' | statusbar --config -

statusbar --config - <<'EOF'
interval = 5
style = fg=blue,bold

[line.uptime]
text = "#(command:uptime)#(fill: )#(datetime:%H:%M)"

[command.uptime]
run = uptime
EOF
```

statusbar reads up to 64 KiB and validates the config before starting the
session. The input must end (EOF); it is not a stream of ongoing updates.
After reading it, statusbar takes keyboard input from `/dev/tty`. A controlling
terminal is required, and stdout must still be a terminal. Empty or invalid
input starts the built-in config with a warning line. To open a file literally named `-`, use `--config ./-`.

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
| `STATUSBAR_STATE`   | the child                  | session indicator, control socket prefix, and config snapshots used by `config` |
| `STATUSBAR_SESSION_ID` | the child               | token for authenticated session requests |
| `STATUSBAR_FIFOS`   | the child                  | private directory for FIFOs created with `statusbar bind` and `push --fifo` |

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
