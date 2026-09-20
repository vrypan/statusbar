# Usage

```
statusbar [run] [options] [-- COMMAND...]
statusbar set <N> [TEXT...]
statusbar init <zsh|fish> [--starship=false] [--report-cwd=false] [--starship-slot N]
statusbar config [--path] [--default | --config PATH]
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

Options take their value as the next argument (`-n 3`), and long options
also after `=` (`--lines=3`). `--lines` requires `--exec`; config height
comes from its `[line.N]` sections.

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
selects another existing slot; it cannot be combined with `--starship=false`.
Slot availability is checked when the generated code finds Starship. Directory
reporting works independently, even with one bar row. Disabling both features
prints nothing, as does running `init` outside a statusbar session.

Reports are sent to the controlling terminal when the directory changes and
before each prompt. Repeating initialization does not duplicate these hooks.

## `config`

Prints the configuration `run` would use: the config file, or the built-in
config when there is none. The config is parsed first, so this also checks
it: a broken file reports its error and exits with status 2.

| Option                | Meaning                                              |
|-----------------------|------------------------------------------------------|
| `--path`              | print only where the config comes from, or `built-in` |
| `--default`           | use the built-in config, ignoring any config file    |
| `-c`, `--config PATH` | use this file, as `run --config` would               |

To start a config of your own from the built-in one:

```sh
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config
```

Use `--default` here: the shell empties the target file before statusbar
reads it, so plain `statusbar config` would find an empty config.

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
| `STATUSBAR_LINES`   | the child and bar commands | desired rows; marks a statusbar session |
| `STATUSBAR_COLUMNS` | bar commands              | the bar's width                          |
| `STATUSBAR_CONFIG`  | read by statusbar         | config file, when `--config` isn't given |
