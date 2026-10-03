# Module library

Modules add a small feature to your running statusbar. Each file contains one
line and its commands with static names such as `disk.usage`. Load a module
with `statusbar config add FILE`. A module is simply a group of config
definitions sharing a prefix; no declaration or registration is needed.

Modules follow the [shared theme style](../themes/README.md#shared-styling-rules):
bold muted `* Label:` prefixes, regular-weight values and dim dotted fills.
They use the theme's `muted` and `rule` colors, with terminal-color fallbacks,
and keep its background. Meters use native green, yellow and red for thresholds.
No special font is required.

## Choose modules

| Module | Shows | Platform and dependencies | Refresh |
| --- | --- | --- | --- |
| [clock](clock.statusbar) | Local date and clock | macOS/Linux; no commands | 1 second |
| [host](host.statusbar) | `user@hostname` | macOS/Linux; `whoami`, `hostname` | 1 hour |
| [load](load.statusbar) | 1-, 5-, and 15-minute load averages | macOS/Linux; `uptime`, `awk` | 10 seconds |
| [disk](disk.statusbar) | Disk usage with a thin meter | macOS/Linux; `df`, `awk` | 1 minute |
| [weather](weather.statusbar) | Conditions and temperature | macOS/Linux; `curl`, `tr`, wttr.in access | 5 minutes |
| [hackernews](hackernews.statusbar) | Top story, linked to its discussion | macOS/Linux; `curl`, `jq`, Hacker News access | 1 minute |
| [github](github.statusbar) | Unread notifications and latest title, linked to your inbox | macOS/Linux; `gh`, `jq`, GitHub access and login | 1 minute |
| [codex](codex.statusbar) | 7-day usage meter, reset countdown, credits, available resets, lifetime tokens | macOS/Linux; `codex-usage`, `jq`, running authenticated Codex daemon | 1 minute |
| [compute](compute.statusbar) | CPU and memory meters | macOS; `top`, `sysctl`, `awk` | 5 seconds |
| [battery](battery.statusbar) | Battery meter and charging/power state | macOS; `pmset`, `awk` | 30 seconds |
| [network](network.statusbar) | Download/upload rates and interface | macOS; `route`, `netstat`, `awk` | 5 seconds |

The built-in theme already includes the host, load, and clock. These modules
are also useful with a smaller starting layout or another theme.

Weather, Hacker News, and GitHub make requests only after you load them.
GitHub uses the account already authenticated with `gh auth login`. Missing
optional tools produce an `install ...` message; request failures show
`unavailable`. macOS-specific modules show `macOS only` on other systems.
Command errors otherwise go to statusbar's discarded stderr; copy the
command into a shell if you need its full diagnostic output.

## Load a module

First start a statusbar session.
Locate the library for your installation:

| Installation | Module directory |
| --- | --- |
| Homebrew build | `$(brew --prefix statusbar)/share/statusbar/modules` |
| Release archive | `modules/` beside `bin/` in the extracted directory |
| Source build | `zig-out/share/statusbar/modules` |
| Repository checkout | `samples/modules` |

From the repository directory, inside the statusbar shell:

```sh
statusbar config add samples/modules/disk.statusbar
statusbar config add samples/modules/weather.statusbar
```

For Homebrew:

```sh
modules_dir="$(brew --prefix statusbar)/share/statusbar/modules"
statusbar config add "$modules_dir/disk.statusbar"
```

New lines appear in import order, above pushed lines. Importing the same
module again fails because its definitions already exist. References are
written explicitly in the file, such as `#(command:disk.usage)`.
To create another instance, copy the file and change its names and references
together before importing the copy.

`config add FILE` checks and sends the module; the session checks it again before
applying it. Inspect the bar and `statusbar config show current` afterward.

## Inspect and remove modules

```sh
statusbar config list
statusbar config remove disk
```

The listing groups configured line and command names by the part before their
first dot. `remove disk` removes all configured `disk.*` lines, commands and
colors. It rejects removal if remaining definitions depend on them, or if it
would leave no configured line. Pushed lines stay. The short forms are
`config ls` and `config rm disk`.

## Customize and save

Each bundled line renders `#(value)`, with its normal display in `default`.
Override a line temporarily and restore its live display with:

```sh
statusbar set codex.usage "HELLO"
statusbar set codex.usage --reset
```

An explicitly empty value clears the value until reset; the label and fill
remain. FIFO input also overrides the value. After editing a module already
loaded in a session,
update its definitions in `config show current` and reload the complete
config; `config add FILE` rejects definitions that already exist.

Copy a module into your own directory before editing it; installed copies may
be replaced by upgrades. Its header lists an example import and requirements.

- **Weather:** set `location` to a city, such as `Athens` or `New+York`.
  An empty location lets wttr.in infer it from the request's IP address.
- **Disk:** set `volume` to the path you want. An empty value selects the
  macOS data volume when present, otherwise `/`.
- **Clock:** edit the `#(datetime:...)` formats.
- **Codex:** put `codex-usage` on `PATH`, or set `CODEX_USAGE_BIN` to its
  executable path before starting statusbar. The module reads one
  `codex-usage snapshot --json` per refresh. Values cover the account, including
  lifetime tokens; they are not limited to the session in the current shell.
  The weekly meter turns yellow at 75% used and red at 90%. `↻` is the time
  until the weekly reset; `resets` counts available reset credits separately
  from spendable credits. Missing values show `—`, unlimited credits show `∞`,
  and an elapsed reset countdown shows `refreshing` until new quota data arrives.
- **Refresh:** edit each command's `interval`. Network commands have explicit
  timeouts where supported; CPU and traffic readings take about one second.
- **Layout:** modules use one line each. To combine features on one line, edit
  a complete config and reference their prefixed commands in the same `text`.

CPU is a one-second sample. Memory comes from `top`'s rounded used-memory
value, not memory pressure. Load averages are runnable/waiting work counts,
not CPU percentages. Network rates cover the default IPv4 interface and are
approximate KiB/s or MiB/s over a one-second sample. Battery shows `AC` on
desktop Macs. GitHub fetches one page of up to 100 notifications and displays
`100+` when that page is full. Hyperlinks work in terminals supporting OSC 8.

Additions affect the current session. To save your assembled layout:

```sh
statusbar config show current > my.statusbar
statusbar config check my.statusbar
```

Start a later session with `statusbar --config my.statusbar`, or copy the
file to your chosen startup config location. To edit definitions, update the
saved complete config and reload it with `statusbar config load my.statusbar`.
Adding or removing definitions preserves unchanged command processes;
replacing the complete config restarts them.

There is a limit of 16 configured commands and 32 named colors per config.
The supplied modules use at most one command each and no named colors, so
the entire library fits alongside any bundled theme. Terminal height still
limits how many rows can be visible.

## Write a module

A module is a `.statusbar` fragment containing `[line.NAME]`, `[command.NAME]`,
and optionally `[colors]`. Choose a static prefix such as `host.`, and use it
in definitions and references:

```ini
[line.host.summary]
default = "#(command:host.fetch)"
text = "#[default,fg=colour8,fg=muted,bold]* Host: #[nobold]#(value) "
text .= "#[default,fg=colour8,fg=rule,dim]#(fill:·)#[default]"

[command.host.fetch]
run = hostname -s
interval = 3600
```

Import with `config add FILE`; the source defines `host.summary` and
`host.fetch`. The import checks name uniqueness and preserves the source as
written. Fragments may contain multiple prefixes or unprefixed definitions.
Snapshots from `config show current` can be saved, checked with
`config check FILE`, and loaded as complete configs. Each bundled module can also be checked directly with
`statusbar config check samples/modules/host.statusbar`.

Module prefixes use letters, digits, underscores and hyphens. Set command intervals
explicitly, use `colour0`–`colour15` or terminal color names, and finish styles
with `#[default]`. Avoid global settings and `[push]` or `[highlight]`, which
belong to the surrounding theme. Each supplied module is self-contained.

`zig build test` validates every module alone and in combination with every
bundled theme. `make test-integration` also exercises module commands using
local fixtures, so checks do not require network access or a GitHub login.
