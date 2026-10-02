# Module library

Modules add a small feature to your running statusbar. Each file contains one
line and its commands with static names such as `disk.usage`. Load a module
with `statusbar config --add NAME`, using its existing prefix.

All modules use the terminal's native palette, keep the theme's background,
and use ordinary Unicode. They need no Nerd Font. Labels use palette magenta
or blue, secondary text uses bright black, and meters use green, yellow, and
red. The actual colors follow your terminal theme.

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

First start a session with a version of statusbar supporting `config --add`.
Locate the library for your installation:

| Installation | Module directory |
| --- | --- |
| Homebrew build | `$(brew --prefix statusbar)/share/statusbar/modules` |
| Release archive | `modules/` beside `bin/` in the extracted directory |
| Source build | `zig-out/share/statusbar/modules` |
| Repository checkout | `samples/modules` |

From the repository directory, inside the statusbar shell:

```sh
statusbar config --add disk < samples/modules/disk.statusbar
statusbar config --add weather < samples/modules/weather.statusbar
```

For Homebrew:

```sh
modules_dir="$(brew --prefix statusbar)/share/statusbar/modules"
statusbar config --add disk < "$modules_dir/disk.statusbar"
```

Use the module's declared prefix: `--add disk` for `disk.usage`, for example.
New lines appear in import order, above pushed lines. Importing the same
module again fails because its definitions already exist. References are
written explicitly in the file, such as `#(command:disk.usage)`.
To create another instance, copy the file and change its names and references
together before importing it under the new prefix.

`config --add` checks and sends the module; the session checks it again before
applying it. Inspect the bar and `statusbar config --print current` afterward.

## Customize and save

Each bundled line renders `#(value)`, with its normal display in `default`.
Override a line temporarily and restore its live display with:

```sh
statusbar set codex.usage "HELLO"
statusbar set codex.usage --reset
```

An explicitly empty value hides the content until reset. FIFO input also
overrides the display. After editing a module already loaded in a session,
update its definitions in `config --print current` and reload the complete
config; `--add` rejects definitions that already exist.

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
- **Layout:** modules use one row each. To combine features on one row, edit
  a complete config and reference their prefixed commands in the same `text`.

CPU is a one-second sample. Memory comes from `top`'s rounded used-memory
value, not memory pressure. Load averages are runnable/waiting work counts,
not CPU percentages. Network rates cover the default IPv4 interface and are
approximate KiB/s or MiB/s over a one-second sample. Battery shows `AC` on
desktop Macs. GitHub fetches one page of up to 100 notifications and displays
`100+` when that page is full. Hyperlinks work in terminals supporting OSC 8.

Additions affect the current session. To save your assembled layout:

```sh
statusbar config --print current > my.statusbar
statusbar config --check my.statusbar
```

Start a later session with `statusbar --config my.statusbar`, or copy the
file to your chosen startup config location. To edit or remove a module
today, edit the saved complete config and reload it with
`statusbar config < my.statusbar`. Keep commands referenced by other lines.
Replacing the complete config restarts its commands; adding a module keeps
existing commands running. A dedicated module-removal command is not yet
available.

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
default = "#[fg=host.accent]#(command:host.fetch)#[default]"
text = "#(value)"

[command.host.fetch]
run = hostname -s
interval = 3600

[colors]
host.accent = colour4
```

Import with `--add host`; the source defines `host.summary`, `host.fetch`,
and `host.accent`. The import checks that prefix and preserves the source as
written. There are no import-time placeholders. Snapshots from
`config --print current` can be saved, checked with `--check`, and loaded as
complete configs. Each bundled module can also be checked directly with
`statusbar config --check samples/modules/host.statusbar`.

Module prefixes use letters, digits, and underscores. Set command intervals
explicitly, use `colour0`–`colour15` or terminal color names, and finish styles
with `#[default]`. Avoid global settings and `[push]` or `[highlight]`, which
belong to the surrounding theme. Each supplied module is self-contained.

`zig build test` validates every module alone and in combination with every
bundled theme. `make test-integration` also exercises module commands using
local fixtures, so checks do not require network access or a GitHub login.
