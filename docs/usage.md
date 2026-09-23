# Usage

```
statusbar [run] [options] [-- COMMAND...]
statusbar set <N> [TEXT...]
statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-slot N]
statusbar config [--print] [--path] [--default]
statusbar completion <bash|zsh|fish>
```

`statusbar --help` lists the commands, and `statusbar COMMAND --help` shows
each one's options.

## `run`

Runs a command, by default `$SHELL`, in a pty shortened by the configured
rows that fit, and keeps a status bar in the rows it gave up. The session
ends when the command exits, with the command's exit status.

`run` is the default command, so it can be left out:
`statusbar -n 1 -- vim` is `statusbar run -n 1 -- vim`. The command to run
always follows `--`.

| Option                  | Meaning                                                                 |
|-------------------------|-------------------------------------------------------------------------|
| `-c`, `--config PATH`   | config file; see [config.md](config.md) for where it is looked for, and the built-in default |
| `-n`, `--lines N`       | row count for `--exec` only (default 1; maximum 65533)                  |
| `-e`, `--exec COMMAND`  | fill the bar from one shell command instead of the config's lines       |
| `-i`, `--interval SECS` | how often commands rerun (default 1 with `--exec`, else the config's)   |
| `-s`, `--style STYLE`   | bar style, as SGR parameters (`7`) or markup attributes (`fg=blue,bold`); `''` for none |
| `--log PATH`           | append runtime diagnostics to a regular file |

Options take their value as the next argument (`-n 3`), and long options
also after `=` (`--lines=3`). `--lines` requires `--exec`; config height
comes from its `[line.N]` sections.

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

`statusbar set N [TEXT...]` replaces a numbered slot of the bar from inside a
session. See [set.md](set.md).

## `init`

`statusbar init zsh` or `statusbar init fish` prints shell integration that
reports the working directory with OSC 7 and moves Starship's prompt into
slot 3 when Starship is available. Both features default to `true`. Zsh
uses `eval "$(statusbar init zsh)"`; Fish uses `statusbar init fish | source`
after Starship's own initialization. See [starship.md](starship.md).

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
| `--print`             | print the config, ignoring stdin                     |
| `--path`              | print only where the config comes from, or `built-in` |
| `--default`           | use the built-in config, ignoring any config file    |

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

## Without a config: `--exec`

A single shell command can fill the bar instead of a config's `[line.N]`
sections. It runs under `/bin/sh -c` every `--interval` seconds, and each
output line fills one bar row, so `-n 3` shows the first three lines.

A line holds up to two slots, separated by a tab: `left` or
`left<TAB>right`. [Markup](config.md#markup), raw SGR colors and OSC 8
hyperlinks are kept; cursor movement and other control characters are
stripped.

```sh
statusbar -i 5 -s '' -e 'printf " #[bold]%s#[default]\t%s \n" "$(hostname -s)" "$(date +%H:%M)"'
```

`--exec` uses reverse video unless `--style` or the config sets another
style. The config's colors and other options still apply, and without a
config file that is the built-in one. A config file with no `[line.N]`
sections shows `date` the same way.

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
