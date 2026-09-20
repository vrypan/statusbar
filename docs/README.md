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
| Notice when a command's value changes | [Highlight changed values](#highlight-changed-values) |
| Show changing directory or Git context | [Update slots from your shell](#put-live-context-in-a-slot) |
| Move Starship's details out of the prompt | [Use Starship](#use-starship) |
| Try a more visual look | [Try a theme](#try-a-theme) |

## Start with one command

For a lightweight bar, no config is needed. `--exec` reruns a shell command;
each output line becomes one row. A tab separates left and right content.

```sh
# A clock at the bottom-right of one row.
statusbar --exec 'printf "\t%s\n" "$(date +%H:%M)"'

# Two rows: host, then date/time.
statusbar --lines 2 --exec 'printf " %s\n\t%s\n" \
  "$(hostname -s)" "$(date "+%a %d %H:%M")"'
```

Use `--interval SECONDS` to control refreshes. `--lines` is only for this
mode; configured layouts derive their row count from the `[line.N]` sections.
See [the command reference](usage.md#without-a-config---exec) for all options.

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

## Highlight changed values

A named command can briefly highlight its slot whenever its displayed result
changes. This is useful for weather, unread notifications, resource metrics,
build state, or anything else that updates in the background:

```ini
[line.1]
left = " Clock #(clock) "

[command.clock]
run = date '+%H:%M:%S'
interval = 1
track = true
```

The first result establishes a baseline; identical later results do nothing.
With the `[highlight]` section from the built-in config, changes play a warm
color pulse. Without that section, the fallback is a 500 ms bold flash. The
whole slot is highlighted, including its label, while the rule and opposite
slot retain their normal appearance.

The built-in effect warms the foreground and background through twelve steps,
then restores every cell's exact original style. Copy the default config to
adjust its colors or speed:

```sh
statusbar config --default > ~/.config/statusbar/config
```

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

For Fish, initialize Starship first:

```fish
starship init fish | source
statusbar init fish | source
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

## Reference and behavior

- [Usage](usage.md) — commands, options, completions, `--exec`, and environment.
- [Configuration](config.md) — rows, commands, change highlights, colors, markup, and rules.
- [Updating slots](set.md) — runtime updates from scripts and the terminal protocol.
- [Starship](starship.md) — prompt integration and customization.
- [Display and animation model](display-model.md) — content updates, animation
  ticks, composed frames, and terminal paints.
- [Internals and limitations](internals.md) — PTY behavior, supported terminal
  interactions, and edge cases relevant to terminal-tool authors.
