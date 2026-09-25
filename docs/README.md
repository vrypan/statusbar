# statusbar guide

statusbar keeps information visible at the bottom of a terminal. Use it for a
clock, project context, build status, or command progress without adding those
details to every prompt.

This guide starts with a small statusbar, then shows how to customize it. Each
`[line.N]` section in a config adds one statusbar line with a left and right side.

## Start with one line

Run the built-in statusbar with `statusbar`. To try a one-line clock instead, pass a
small config directly:

```sh
statusbar --config - <<'EOF'
[line.1]
right = %H:%M
EOF
```

To leave, exit the shell inside statusbar. A script can also write a config to
standard input; see [configs from stdin](usage.md#generate-a-config-on-the-fly).

## Make a config

Create a starting config, then edit it:

```sh
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config
statusbar
```

Each `[line.N]` section adds a line. Lines have a left and right side. You can
replace the starter config with this two-line example:

```ini
[line.1]
left = " Ready "
right = %H:%M

[line.2]
left = "Host #(hostname)"
```

`%H:%M` shows the current time. `#(hostname)` runs the command and shows its
first output line. By default, commands run every five seconds. You can add
colors, change intervals, and fill the space between sides with a `rule`;
see [configuration](config.md).

statusbar keeps at least two terminal rows for your shell. Configured statusbar lines
that do not fit are hidden until the window grows.

## Put live context in a slot

Config commands are ideal for machine-wide information such as load, battery,
or time. They run from the directory where statusbar started, so they cannot
follow your shell's `cd`. For directory-specific information, update a
numbered slot from the shell instead.

Slots are numbered left-to-right, top-to-bottom: line 1 uses slots 1 and 2,
line 2 uses 3 and 4, and so on.

```zsh
# ~/.zshrc: put the current directory in slot 1 before each prompt.
__statusbar_cwd() {
  statusbar set 1 -- "$PWD"
}
precmd_functions+=(__statusbar_cwd)
```

Calling `statusbar set 1` with no text restores the value from the config.
`statusbar set` is a no-op outside a statusbar session, so the same shell setup
works in regular terminals. [Updating slots](set.md) has Bash and Fish hooks,
formatting details, and examples for scripts.

## Give a command its own line

Use `push` for output that changes while a command runs:

```sh
statusbar push -t build -- make
```

The new line shows the latest output line and stays visible when `make` ends.
`push` prints the line's ID so you can remove it later with `statusbar pop ID`.
Use `statusbar pop` without an ID to remove the newest line. See
[temporary lines](push.md) for pipes, logs, progress bars, and styling.

## Use Starship

If you already use [Starship](https://starship.rs), keep its prompt character
in the terminal and move its useful details—directory, Git state, durations,
and language versions—into a statusbar slot:

```zsh
eval "$(statusbar init zsh)"
```

This also reports your current directory for the terminal title. Both features
are enabled by default. Add `--report-cwd=false` if another integration already
reports directories, or `--starship=false` to use only directory reporting.

For Fish, initialize Starship first:

```fish
starship init fish | source
statusbar init fish | source
```

For Nushell, copy [the integration sample](../samples/statusbar.nu) to
`~/.config/nushell/statusbar.nu`, then source it from `config.nu`:

```nu
source ~/.config/nushell/statusbar.nu
```

By default this uses slot 3, the left side of line 2. Choose a different slot
when designing a larger layout:

```zsh
eval "$(statusbar init zsh --starship-slot 5)"
```

[The Starship guide](starship.md) explains the automatic integration, shell
ordering, and how to select modules or use a dedicated Starship profile for
statusbar.

## Try a theme

The repository includes four ready-to-run themes based on familiar Starship
styles: [Pure](../samples/themes/pure.config),
[Tokyo Night](../samples/themes/tokyo-night.config),
[Gruvbox](../samples/themes/gruvbox.config), and
[Pastel Powerline](../samples/themes/pastel-powerline.config).

From the repository checkout, try one without replacing your config:

```sh
statusbar --config ./samples/themes/tokyo-night.config
```

The Gruvbox and Pastel Powerline themes need Powerline glyphs, usually supplied
by a Nerd Font. Pure and Tokyo Night use ordinary terminal text and Unicode.
The themes are a good way to explore backgrounds, colored labels, rules, and
restrained use of icons; see [their notes](../samples/themes/README.md).

## Load another config

Inside a running statusbar session, send a config to `statusbar config` to
replace the whole layout. From the repository checkout, for example:

```sh
statusbar config < ./samples/themes/tokyo-night.config
statusbar config --default | statusbar config
```

Statusbar checks the new config before applying it. If it is invalid, the
current layout stays in place. A valid one can add or remove lines without
restarting the shell. Only load config files you trust, since they can run
commands. See [configuration](config.md#replace-the-running-config) for what
happens to slot values and pushed lines; the [protocol](osc-3110.md) is there
for programs that send config changes directly.

## Highlight changed values

Wrap a value in `#[track]...#[notrack]` to briefly highlight it when its displayed
content changes. This works for commands and template clocks, and is useful for
weather, unread notifications, resource metrics, or build state:

```ini
[line.1]
left = " Clock #[track]#(clock)#[notrack] "

[command.clock]
run = date '+%H:%M:%S'
interval = 1
```

The first result sets a baseline. Later changes briefly highlight only the
marked text. You can mark more than one value in a slot:

```ini
left = "CPU #[track]#(cpu)#[notrack]  MEM #[track]#(mem)#[notrack]"
```

The default effect makes two pulses over 2.4 seconds. Set `pulses = 1` or
`pulses = 3` under `[highlight]` to change the duration. See
[highlight settings](config.md#highlight-changes) for the full behavior and
older-config migration details.

## Reference and behavior

- [How I use statusbar](how-i-use-statusbar.md) — a minimal everyday statusbar and a richer optional layout.
- [Usage](usage.md) — commands, options, completions, generated configs, and environment.
- [Configuration](config.md) — lines, commands, change highlights, colors, markup, and rules.
- [Updating slots](set.md) — runtime updates from scripts and the terminal protocol.
- [Pushing lines](push.md) — stream output into a new line and remove it by ID.
- [Starship](starship.md) — prompt integration and customization.
- [Display and animation model](display-model.md) — content updates, animation
  ticks, composed frames, and terminal paints.
- [Internals and limitations](internals.md) — PTY behavior, supported terminal
  interactions, and edge cases relevant to terminal-tool authors.

## Contributing and testing

Run `make check` for formatting and unit tests. Before shipping a change, run
`make test-integration`: it builds the native binary and exercises it in a
simulated terminal, including shell integration. Install zsh and fish to cover
both shell-specific cases; missing shells are explicitly reported as skipped.
The generic terminal checks always run. Release verification installs both
shells and runs this gate before building release archives.

For rendering measurements, run `zig build bench -Doptimize=ReleaseFast`.
It separates first-use color preparation from repeated effects and tests
multiple colors and tracked regions. See [measurement details](internals.md#resource-limits-and-measurement)
before comparing timings; a single warm frame does not predict first-use cost.
