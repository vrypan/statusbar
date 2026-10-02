# Module library

Modules add a small feature to your running statusbar. Each file contains one
line and its commands, with names prefixed by the module name. Choose the
modules you want and load them with `statusbar config --add NAME`.

All modules use the terminal's native palette, keep the theme's background,
and use ordinary Unicode. They need no Nerd Font. Labels use palette magenta
or blue, secondary text uses bright black, and meters use green, yellow, and
red. The actual colors follow your terminal theme.

## Choose modules

| Module / prefix | Shows | Platform and dependencies | Refresh |
| --- | --- | --- | --- |
| [clock](clock.statusbar) | Local date and clock | macOS/Linux; no commands | 1 second |
| [host](host.statusbar) | `user@hostname` | macOS/Linux; `whoami`, `hostname` | 1 hour |
| [load](load.statusbar) | 1-, 5-, and 15-minute load averages | macOS/Linux; `uptime`, `awk` | 10 seconds |
| [disk](disk.statusbar) | Disk usage with a thin meter | macOS/Linux; `df`, `awk` | 1 minute |
| [weather](weather.statusbar) | Conditions and temperature | macOS/Linux; `curl`, `tr`, wttr.in access | 5 minutes |
| [hackernews](hackernews.statusbar) | Top story, linked to its discussion | macOS/Linux; `curl`, `jq`, Hacker News access | 1 minute |
| [github](github.statusbar) | Unread notifications and latest title, linked to your inbox | macOS/Linux; `gh`, `jq`, GitHub access and login | 1 minute |
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

Use the prefix in the table even if you rename the file. New lines appear in
the order modules are loaded, above any pushed lines. Loading the same module
twice fails because its definitions already exist. References to commands
use their full names, such as `#(command:disk-usage)`.

`config --add` checks and sends the module; the session checks it again before
applying it. Inspect the bar and `statusbar config --print current` afterward.

## Customize and save

Copy a module into your own directory before editing it; installed copies may
be replaced by upgrades. Its header lists the prefix and requirements.

- **Weather:** set `location` to a city, such as `Athens` or `New+York`.
  An empty location lets wttr.in infer it from the request's IP address.
- **Disk:** set `volume` to the path you want. An empty value selects the
  macOS data volume when present, otherwise `/`.
- **Clock:** edit the `#(datetime:...)` formats.
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

A module is an ordinary `.statusbar` fragment containing `[line.NAME]`,
`[command.NAME]`, and optionally `[colors]`. Prefix every new name with the
module name and `-`; for example, module `weather` defines `weather-current`.
Module prefixes use letters, digits, and underscores. Set command intervals
explicitly, use `colour0`–`colour15` or terminal color names, and finish styles
with `#[default]`. Avoid global settings and `[push]` or `[highlight]`, which
belong to the surrounding theme. Each supplied module is self-contained.

`zig build test` validates every module alone and in combination with every
bundled theme. `make test-integration` also exercises module commands using
local fixtures, so checks do not require network access or a GitHub login.
