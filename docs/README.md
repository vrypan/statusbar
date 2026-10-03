# statusbar guide

statusbar keeps information visible at the bottom of a terminal. Use it for a
clock, project context, build status, or command progress without adding those
details to every prompt.

This guide starts with a small statusbar, then shows how to customize it. Each
`[line.NAME]` section in a config adds one named line with its own template.

## Start with one line

Run the built-in statusbar with `statusbar`. To try a one-line clock instead, pass a
small config directly:

```sh
statusbar --config - <<'EOF'
[line.clock]
text = "#(fill: )#(datetime:%H:%M)"
EOF
```

To leave, exit the shell inside statusbar. A script can also write a config to
standard input; see [configs from stdin](usage.md#generate-a-config-on-the-fly).

## Make a config

Create a starting config, then edit it:

```sh
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config.statusbar
statusbar
```

Each `[line.NAME]` section adds a line, in the order the sections appear. A
line's `text` is a template. Text before `#(fill:PATTERN)` sits on the left,
text after it on the right, and the pattern fills the space between. You can
replace the starter config with this two-line example:

```ini
[line.status]
text = " Ready#(fill: )#(datetime:%H:%M) "

[line.host]
text = " Host #(command:host)"

[command.host]
run = hostname
interval = 60
```

`#(datetime:%H:%M)` shows the current time. `#(command:host)` shows the first
output line of `[command.host]`. Commands without an `interval` run every five
seconds. You can add colors, draw rules such as `#(fill:─)`, and give lines
backgrounds; see [configuration](config.md). If you have a config from an
earlier version, see the [migration guide](migration.md).

statusbar keeps at least two terminal rows for your shell. Configured statusbar lines
that do not fit are hidden until the window grows.

## Put live context in a line

Config commands are ideal for machine-wide information such as load, battery,
or time. They run from the directory where statusbar started, so they cannot
follow your shell's `cd`. For directory-specific information, set a line's
value from the shell instead. A line shows its value with `#(value)`, which is
also the template of a line without `text`:

```ini
[line.cwd]
```

```zsh
# ~/.zshrc: show the current directory before each prompt.
__statusbar_cwd() {
  statusbar set cwd -- "$PWD"
}
precmd_functions+=(__statusbar_cwd)
```

`statusbar set cwd --reset` restores the line's `default`. Lines also have a
status (`normal`, `running`, `done`, `success` or `failed`) that can select a
different template, for example to color a build line:

```sh
statusbar set build "12 tests passed" --status success
```

`statusbar set` is a no-op outside a statusbar session, so the same shell setup
works in regular terminals. [Changing a line](set.md) has Bash and Fish hooks
and the details of values and statuses.

## Give a command its own line

Use `push` for output that changes while a command runs:

```sh
statusbar push build -- make
```

The new line shows the latest output line and stays visible when `make` ends,
marked as succeeded or failed. `push` prints the line's name, its numeric ID
when you don't give one, so you can remove it later with `statusbar pop NAME`.
Use `statusbar pop` without a name to remove the newest line. See
[temporary lines](push.md) for pipes, logs, progress bars, and styling.

For output from commands that only know how to write to a file, create a
[FIFO](bind.md): `statusbar push build --fifo` creates a line and prints a
pipe path, and `statusbar bind cwd` gives an existing line one.

## Use Starship

If you already use [Starship](https://starship.rs), keep its prompt character
in the terminal and move its useful details (directory, Git state, durations,
and language versions) into a statusbar line:

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

The details become the value of the line named `prompt`, which the built-in
config and the themes provide. Choose a different line when designing a
larger layout:

```zsh
eval "$(statusbar init zsh --starship-line status)"
```

[The Starship guide](starship.md) explains the automatic integration, shell
ordering, and how to select modules or use a dedicated Starship profile for
statusbar.

## Try a theme

The repository includes four ready-to-run themes based on familiar Starship
styles: [Pure](../samples/themes/pure.statusbar),
[Tokyo Night](../samples/themes/tokyo-night.statusbar),
[Gruvbox](../samples/themes/gruvbox.statusbar), and
[Pastel Powerline](../samples/themes/pastel-powerline.statusbar).

Each has a `-native.statusbar` version that follows your terminal's palette,
such as [Pure Native](../samples/themes/pure-native.statusbar). The
[theme directory](../samples/themes/README.md) also includes Minimal and
Multi-line layouts, both with native variants.

Inside a running session, use `statusbar-theme /path/to/themes` to browse
and activate a `.statusbar` file with the keyboard. The picker changes the
current session without writing your saved config.

From the repository checkout, try one without replacing your config:

```sh
statusbar --config ./samples/themes/tokyo-night.statusbar
```

The Gruvbox and Pastel Powerline themes need Powerline glyphs, usually supplied
by a Nerd Font. Pure and Tokyo Night use ordinary terminal text and Unicode.
The themes are a good way to explore backgrounds, colored labels, rules, and
restrained use of icons; see [their notes](../samples/themes/README.md).

## Add a module

The [module library](../samples/modules/README.md) contains ready-made features
with native terminal colors. Add one inside a running session:

```sh
statusbar config --add < samples/modules/disk.statusbar
```

This adds the module's line and commands to the current layout. Existing
lines and commands keep running. See the library for installation paths,
platform requirements, and how to customize and save your modules.

## Load another config

Inside a running statusbar session, send a config to `statusbar config` to
replace the whole layout. From the repository checkout, for example:

```sh
statusbar config < ./samples/themes/tokyo-night.statusbar
statusbar config --default | statusbar config
```

Statusbar checks the new config before applying it. If it is invalid, the
current layout stays in place. A valid one can add, remove, or reorder lines
without restarting the shell; lines keep their values and statuses by name.
Only load config files you trust, since they can run commands. See
[configuration](config.md#replace-the-running-config) for what happens to
values and pushed lines; the [protocol](osc-3110.md) is there for programs that
send config changes directly.

If the config a session starts with is invalid or unreadable, statusbar still
starts your shell, with the built-in config and a line describing the problem.

## Highlight changed values

Wrap a value in `#[track]...#[notrack]` to briefly highlight it when its displayed
content changes. This works for commands and dates, and is useful for weather,
unread notifications, resource metrics, or build state:

```ini
[line.clock]
text = " Clock #[track]#(command:clock)#[notrack] "

[command.clock]
run = date '+%H:%M:%S'
interval = 1
```

The first result sets a baseline. Later changes briefly highlight only the
marked text. You can mark more than one value in a template:

```ini
text = "CPU #[track]#(command:cpu)#[notrack]  MEM #[track]#(command:mem)#[notrack]"
```

The default effect makes two pulses over 2.4 seconds. Set `pulses = 1` or
`pulses = 3` under `[highlight]` to change the duration. See
[highlight settings](config.md#highlight-changes) for the full behavior.

## Reference and behavior

- [How I use statusbar](how-i-use-statusbar.md) — a minimal everyday statusbar and a richer optional layout.
- [Usage](usage.md) — commands, options, completions, generated configs, and environment.
- [Configuration](config.md) — lines, templates, fill, statuses, commands, change highlights, colors, and markup.
- [Migrating from slots](migration.md) — converting configs, scripts and hooks from earlier versions.
- [Changing a line](set.md) — values, statuses, and the control protocol.
- [Pushing lines](push.md) — stream output into a new line and remove it.
- [FIFOs](bind.md) — redirect output to a pushed or configured line.
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
