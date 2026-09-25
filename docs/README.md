# statusbar guide

statusbar gives a terminal session a persistent area at its bottom. Use it to
keep context that is useful between commands—where you are, what branch you
are on, whether work succeeded, or what the machine is doing—without putting
that information in every prompt.

It runs your shell in a slightly smaller pseudo-terminal and paints the bar in
the rows below it. Your shell, full-screen programs, and scrollback continue
to work normally.

This guide calls the visible parts of the bar *rows*. In a config file, each
`[line.N]` section defines one row.

## Choose a starting point

| Goal | Start here |
|---|---|
| Show a clock or one command's output | [A single command](#start-with-one-command) |
| Build a persistent personal layout | [Make a config](#make-a-config) |
| Change layouts without restarting the shell | [Load another config](#load-another-config) |
| Notice when a command's value changes | [Highlight changed values](#highlight-changed-values) |
| Show changing directory or Git context | [Update slots from your shell](#put-live-context-in-a-slot) |
| Give a command its own temporary row | [Push a stream into a row](push.md) |
| Move Starship's details out of the prompt | [Use Starship](#use-starship) |
| Try a more visual look | [Try a theme](#try-a-theme) |
| See an everyday setup with actual configs | [How I use statusbar](how-i-use-statusbar.md) |

## Start with one command

For a lightweight bar, pass a small config directly:

```sh
statusbar --config - <<'EOF'
[line.1]
right = %H:%M
EOF
```

Scripts can generate one too: `generate-config | statusbar --config -`.
See [the command reference](usage.md#generate-a-config-on-the-fly) for details.

## Make a config

Create a starting config, then edit it:

```sh
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config
statusbar
```

Each consecutive `[line.N]` section creates a row. Every row has a left and
right slot; an optional `rule` fills the unused space between them. This
three-row layout has a labeled divider, stable machine information, and room
for live project context:

```ini
interval = 5

[colors]
accent = #89b4fa
muted = #6c7086

[line.1]
left = " Build "
right = " ready "
rule = ─
style = fg=muted

[line.2]
left = " #[fg=accent,bold]#(hostname -s)#[default] · load #(load)"
right = "%a %d  #[bold]%H:%M:%S#[default] "

[line.3]
left = "Project context appears here"

[command.load]
run = uptime | awk -F'load averages?: ' '{print $2}'
interval = 10
```

The terminal shows as many configured rows as fit while preserving at least
two rows for the program inside it. Rows that do not fit are hidden and return
when the terminal grows. [Configuration](config.md) explains templates,
commands, markup, colors, rules, and all layout details.

## Load another config

Inside a running statusbar session, pipe a config into `statusbar config` to
replace the whole configuration:

```sh
cat ./themes/dark.config | statusbar config
statusbar config --default | statusbar config
```

The command reads the file locally and sends its contents to the running
session. See [configuration](config.md#replace-the-running-config) for the
transactional behavior and [OSC config replacement](osc-3110.md) for the wire
format and size limit.

The running statusbar validates the config before replacing anything; an
invalid one leaves the current bar unchanged. A successful load
can add or remove rows and change every configuration setting without restarting
the shell or foreground program. Overrides in numbered slots that still exist
are retained. Config files run shell commands, so load only files you trust.

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

The first result establishes a baseline; identical later results do nothing.
By default, changes play two smooth pulses over 2.4 seconds, derived from each
grapheme's own foreground and background colors, using your terminal's palette. The
marked region is highlighted; its label and other content keep their normal
appearance. Several regions in one slot can change width and pulse independently:

```ini
left = "CPU #[track]#(cpu)#[notrack]  MEM #[track]#(mem)#[notrack]"
```

The background smoothly moves toward the text's lightness, then returns:
dark backgrounds brighten and light backgrounds darken. The foreground adjusts
alongside it, and a contrast safeguard limits the pulse to keep text readable.
Gray text on a dark background sweeps toward near-white; on a light background,
the text moves toward near-black. Colored text keeps its hue where possible.
Between peaks, the highlight softens without returning to the original styling;
the original colors return only when the whole animation ends.
Styles and hyperlinks are preserved. If the terminal cannot report a needed
color, that grapheme uses a bold fallback.

```ini
[highlight]
pulses = 2
```

Use `pulses = 1` for 1.2 seconds or `pulses = 3` for 3.6 seconds. Each pulse
keeps the same pace; more pulses give you longer to notice the changed value.
Older `effect`, custom highlight color, and `step` settings are no longer
accepted; remove them when upgrading. Markup colors remain configurable.

See [Highlight changes](config.md#highlight-changes) for the complete behavior
and `[highlight]` reference.

## Put live context in a slot

Config commands are ideal for machine-wide information such as load, battery,
or time. They run from the directory where statusbar started, so they cannot
follow your shell's `cd`. For directory-specific information, update a
numbered slot from the shell instead.

Slots are numbered left-to-right, top-to-bottom: line 1 uses slots 1 and 2,
line 2 uses 3 and 4, and so on.

```zsh
# Put the current directory in the left side of line 3 before each prompt.
__statusbar_cwd() {
  statusbar set 5 -- "$PWD"
}
precmd_functions+=(__statusbar_cwd)
```

The same idea works in Bash and Fish. If another prompt framework manages
these hooks, add the update through that framework instead of replacing its
hook outright.

```bash
# ~/.bashrc
__statusbar_cwd() {
  local previous_status=$?
  statusbar set 5 -- "$PWD"
  return "$previous_status"
}
PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}; }__statusbar_cwd"
```

```fish
# ~/.config/fish/config.fish
function __statusbar_cwd --on-event fish_prompt
  statusbar set 5 -- "$PWD"
end
```

Calling `statusbar set 5` with no text restores the value from the config.
Pipe output to `statusbar set 5 -` to show its latest line as it arrives;
see [streaming updates](set.md#stream-the-latest-line).
The command is a no-op outside a statusbar session, so the same shell setup
works in regular terminals. [Updating slots](set.md) covers numbering,
formatting, and sending updates from scripts.

## Use Starship

If you already use [Starship](https://starship.rs), keep its prompt character
in the terminal and move its useful details—directory, Git state, durations,
and language versions—into a bar slot:

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
the bar.

## Try a theme

The repository includes four ready-to-run themes based on familiar Starship
styles: [Pure](../samples/themes/pure.config),
[Tokyo Night](../samples/themes/tokyo-night.config),
[Gruvbox](../samples/themes/gruvbox.config), and
[Pastel Powerline](../samples/themes/pastel-powerline.config).

Try one without replacing your config:

```sh
statusbar --config /path/to/statusbar/samples/themes/tokyo-night.config
```

The Gruvbox and Pastel Powerline themes need Powerline glyphs, usually supplied
by a Nerd Font. Pure and Tokyo Night use ordinary terminal text and Unicode.
The themes are a good way to explore backgrounds, colored labels, rules, and
restrained use of icons; see [their notes](../samples/themes/README.md).

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

## Reference and behavior

- [Usage](usage.md) — commands, options, completions, generated configs, and environment.
- [Configuration](config.md) — rows, commands, change highlights, colors, markup, and rules.
- [Updating slots](set.md) — runtime updates from scripts and the terminal protocol.
- [Pushing rows](push.md) — stream output into a new row and remove it by ID.
- [Starship](starship.md) — prompt integration and customization.
- [Display and animation model](display-model.md) — content updates, animation
  ticks, composed frames, and terminal paints.
- [Internals and limitations](internals.md) — PTY behavior, supported terminal
  interactions, and edge cases relevant to terminal-tool authors.
