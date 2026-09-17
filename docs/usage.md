# Usage

```
statusbar [options] [-- command [args...]]
statusbar set left|right [TEXT...]
eval "$(statusbar init zsh)"
```

`statusbar` runs a command, by default `$SHELL`, in a pty one or two rows
shorter than the terminal, and keeps a status bar in the rows it gave up.
The session ends when the command exits, with the command's exit status.

## Options

| Option                  | Meaning                                                                 |
|-------------------------|-------------------------------------------------------------------------|
| `-c`, `--config PATH`   | config file; see [config.md](config.md) for where it is looked for      |
| `-n`, `--lines N`       | bar height, 1 or 2 (default: from the config, else 1)                   |
| `-p`, `--position POS`  | `bottom` (default) or `top`                                             |
| `-e`, `--exec COMMAND`  | fill the bar from one shell command instead of the config's lines       |
| `-i`, `--interval SECS` | how often commands rerun (default 1 with `--exec`, else the config's)   |
| `-s`, `--style STYLE`   | bar style, as SGR parameters (`7`) or markup attributes (`fg=blue,bold`); `''` for none |
| `-h`, `--help`          | show help                                                               |
| `-V`, `--version`       | show the version                                                        |

Options take their value as the next argument, and long options also after
`=` (`--lines=2`). Options override the config file.

A command whose name starts with `-`, or is `set` or `init`, must follow
`--`: `statusbar -- set`.

## Subcommands

- `statusbar set left|right [TEXT...]` replaces a slot of the bar from
  inside a session. See [set.md](set.md).
- `statusbar init zsh` prints the zsh integration that moves starship's
  prompt into the bar. See [starship.md](starship.md).

## Without a config: `--exec`

A single shell command can fill the bar instead of a config's `[line.N]`
sections. It runs under `/bin/sh -c` every `--interval` seconds, and each
output line fills one bar row, so `-n 2` shows the first two lines.

A line holds up to two slots, separated by a tab: `left` or
`left<TAB>right`. [Markup](config.md#markup), raw SGR colors and OSC 8
hyperlinks are kept; cursor movement and other control characters are
stripped.

```sh
statusbar -i 5 -s '' -e 'printf " #[bold]%s#[default]\t%s \n" "$(hostname -s)" "$(date +%H:%M)"'
```

With neither `--exec` nor a config with `[line.N]` sections, the bar shows
`date` in reverse video. `--exec` also uses reverse video unless `--style` or
the config sets another style; a config's colors and other options still
apply.

## Environment

| Variable            | Set for                   | Meaning                                  |
|---------------------|---------------------------|------------------------------------------|
| `STATUSBAR_LINES`   | the child and bar commands | bar height; marks a statusbar session   |
| `STATUSBAR_COLUMNS` | bar commands              | the bar's width                          |
| `STATUSBAR_CONFIG`  | read by statusbar         | config file, when `--config` isn't given |
