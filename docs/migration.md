# Migrating from slots

Earlier versions divided each `[line.N]` into numbered left and right slots.
statusbar now uses named lines with one template each, explicit expressions,
and a value and status per line. This is a breaking change: old configs,
`statusbar set N`, `statusbar fifo` and the OSC slot sequence no longer work.
This guide converts each part.

## Where configs live

The default config moved from `~/.config/statusbar/config` to
`~/.config/statusbar/config.statusbar` (under `$XDG_CONFIG_HOME` when it is
set). The old file is never loaded. If it is the only one present, statusbar
starts with the built-in config and a line pointing at it, and your shell
starts as usual. Convert it, save it under the new name, validate the draft,
then load it without restarting:

```sh
statusbar config check ~/.config/statusbar/config.statusbar
statusbar config < ~/.config/statusbar/config.statusbar
```

A valid replacement removes the warning line. Any config that cannot be used
at startup, including one named by `--config` or `$STATUSBAR_CONFIG`, is
handled the same way: the built-in config and a warning, never a shell that
fails to start. `statusbar config show path` shows the file a new session loads.

Shipped themes and samples now end in `.statusbar`; `--config` accepts any
file name.

## One line

```ini
# Before
[line.1]
left  = " #(hostname -s)"
right = "%H:%M "
```

```ini
# After
[line.host]
text = " #(command:host)#(fill: )#(datetime:%H:%M) "

[command.host]
run = hostname -s
```

- `[line.N]` becomes `[line.NAME]`. Names use letters, digits, `_` and `-`,
  and cannot be only digits.
- `left` and `right` become one `text`: left side, `#(fill: )`, right side.
- `#(anything)` no longer runs a shell command. Define `[command.NAME]` and
  write `#(command:NAME)`; `#(NAME)` alone is an error.
- `%H:%M` in plain text is now literal. Use `#(datetime:%H:%M)`.

## Several lines

Lines appear in the order their sections are first declared, not by number:

```ini
# Before
[line.2]
left = second
[line.1]
left = first
```

```ini
# After
[line.first]
text = first
[line.second]
text = second
```

## Rules and styles

`rule` becomes the fill pattern. A line's `style` becomes an inline style at
the start of the template:

```ini
# Before
[line.1]
rule  = ─
style = fg=brightblack

[line.2]
style = fg=white,bg=#1e1e2e
left  = " #[bold]main#[default] · load"
right = "12:00 "
```

```ini
# After
[line.rule]
text = "#[fg=brightblack]#(fill:─)"

[line.status]
text = "#[fg=white,bg=#1e1e2e] #[bold]main#[default,fg=white,bg=#1e1e2e] · load"
text .= "#(fill: )12:00 "
```

- `#[default]` now returns to the bar's top-level `style`, not the line's.
  Write `#[default,fg=...,bg=...]` to return to a line style.
- A style carries on through the fill and the right side, which used to start
  fresh. Reset it before the fill if the rule should look different.
- A line background needs a fill, usually of spaces, to cover the whole row.
  Without a fill, unused cells use the top-level `style`.
- A template left of a rule used to get a one-column gap from the right side;
  add spaces yourself where you want them.

## Long templates

Split a template over several assignments with `.=`. Fragments join exactly,
with no added spaces or newlines, and the 32-part limit of old templates is
gone:

```ini
[line.status]
text = "#[fg=accent] #(command:user)@#(command:host)"
text .= " · load #(command:load)"
text .= "#(fill: )"
text .= "#(datetime:%a %d %b) #(datetime:%H:%M) "

[command.user]
run = whoami
[command.host]
run = hostname -s
[command.load]
run = uptime | awk -F'load averages?: ' '{ split($2, a, /[, ]+/); print a[1] }'
```

## Narrow terminals

When a line does not fit, the left side used to be kept and the right side
clipped. That is still the default, `keep = left`. Set `keep = right` to keep
the right side instead. Without a fill, `keep = right` keeps the end of the
text, still starting at the left edge.

## Setting values

`statusbar set N TEXT` addressed a slot number. `statusbar set NAME TEXT` now
sets a line's value, shown by `#(value)`:

```ini
# Before
[line.2]
left  = "no build yet"
right = "%H:%M"
```

```sh
statusbar set 3 "Build passed"     # before: slot 3 = line 2, left
statusbar set 3                    # before: restore
```

```ini
# After
[line.build]
default = "no build yet"
text = "#(value)#(fill: )#(datetime:%H:%M)"
```

```sh
statusbar set build "Build passed"
statusbar set build --reset
```

- `set NAME` with no text now changes nothing; use `--reset` to restore the
  default. `set NAME ""` sets an explicit empty value.
- A value no longer replaces the whole slot: the rest of the template, dates
  and commands keep updating.
- Values are literal. `#[fg=green]` in a value used to style it; now it is
  shown as written. ANSI colors in a value still work, so
  `statusbar set build "$(printf '\033[32mok\033[0m')"` is green.
- A decimal target is a line ID, not a slot or position. Configured lines get
  IDs 1, 2, … in order at startup, but prefer names.

## Statuses

Lines have a status: `normal`, `running`, `done`, `success` or `failed`, set
with `--status`. Status templates in the same section replace `text`:

```ini
[line.build]
default = "no build yet"
text    = "#(value)"
running = "#[fg=yellow]● #(value)"
success = "#[fg=green]✓ #(value)"
failed  = "#[fg=red]✗ #(value)"
```

```sh
statusbar set build "compiling" --status running
statusbar set build "12 tests passed" --status success
```

## Pushed lines

`[line.push]`, `[line.push.done]`, `[line.push.success]` and
`[line.push.failed]` become one `[push]` section with status templates.
`#(stream)` is `#(value)`; `#(tag)` and `#(id)` are both `#(name)`:

```ini
# Before
[line.push]
style = fg=brightblack
left  = "[#(id)] #(tag) > #(stream)"
[line.push.failed]
right = "exit #(exit_code)"
```

```ini
# After
[push]
text   = "#[fg=brightblack]#(value)#(fill: )[#(name)]"
failed = "#[fg=brightblack]#(value)#(fill: )#[fg=red]failed#[fg=brightblack] [#(name)]"
```

- `#(exit_code)` and `#(signal)` are gone. A command's result selects
  `success` (exit 0) or `failed`; `push` still exits with the command's
  status.
- `spinner` and `spinner_interval` move to `[push]`.
- Pushed lines keep the right side by default (`keep = right`), so the name
  stays visible.

On the command line, the tag becomes the line's name:

```sh
statusbar push -t build -- make        # before
statusbar push build -- make           # after
```

`push` prints the name when input ends; an unnamed push prints its numeric
ID, as before. `pop` takes a name or ID.

## FIFOs

`statusbar fifo` is replaced by `bind` and `push --fifo`:

| Before | After |
|--------|-------|
| `statusbar fifo build` | `statusbar push build --fifo` |
| `statusbar fifo --slot 3 prompt` | `statusbar bind prompt` (for a `[line.prompt]`) |
| `statusbar fifo --finish --exit-code 0 build` | `statusbar set build --status success` |
| `statusbar fifo --finish build` | `statusbar set build --status done` |
| `statusbar fifo --start build` | `statusbar set build --status running` |
| `statusbar fifo --remove prompt` | `statusbar bind -u prompt` |
| `$STATUSBAR_SLOTS/build` | the path printed by `bind`/`push --fifo`, in `$STATUSBAR_FIFOS` |

A FIFO now keeps accepting input after any status change. Removing a binding
keeps the line's value and status; `pop` removes a pushed line and its FIFO.

## Shell integration

`statusbar init --starship-slot N` becomes `--starship-line NAME`, defaulting
to a line named `prompt`. Give your config a `[line.prompt]` whose template
includes `#(value)`. In the Nushell sample, `set 3 --` becomes
`set prompt --`. Scripts that sent the OSC 1337 `SetUserVar=StatusBarSlotN`
sequence directly should call `statusbar set` instead; statusbar no longer
consumes that sequence.

## Command output

Command output is now literal, like values: `#[...]` printed by a command is
shown as written instead of styling the line. Print ANSI escapes instead, or
move the styling into the template around `#(command:NAME)`:

```sh
# Before, inside [command.status]
printf '#[fg=green]up#[default]\n'
# After
printf '\033[32mup\033[0m\n'
```

## Reloading

`statusbar config < FILE` used to keep slot overrides where the same slot
number existed. It now keeps each configured line's value and status by name,
and moves the line to its new position. A line still showing its default
shows the new config's default. Removing a line from the config removes its
FIFO. Pushed lines stay, and a config cannot add a line named like one of
them.
