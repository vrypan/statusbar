# statusbar

A status bar at the bottom of your terminal. It keeps useful information
visible while you work, without repeating it in every prompt. Your shell,
full-screen programs, and scrollback continue to work.

![screenshot](demo/screenshot.png)

## Quick start

Install with Homebrew:

```sh
brew install vrypan/tap/statusbar
```

Or download the latest [release](https://github.com/vrypan/statusbar/releases).

Or build from source with Zig 0.16 on macOS or Linux:

```sh
zig build -Doptimize=ReleaseSafe
# Binaries: zig-out/bin/statusbar and zig-out/bin/statusbar-theme
```

After installing, start statusbar (for a source build, use
`./zig-out/bin/statusbar` from the repository directory):

```sh
statusbar
```

This starts your usual shell with a status bar.

Exit it to return to your original session.

## Configure using an AI agent

You can use an AI agent to configure statusbar and make a personal theme.

Use a prompt like:

```
Read @AGENT_SETUP.md and follow it to help me set up my installed statusbar and create a custom theme.
```

[AGENT_SETUP.md](AGENT_SETUP.md) is at the root of a release
tarball or at `$(brew --prefix statusbar)/share/statusbar/AGENT_SETUP.md`
after a Homebrew install.

## Choose a theme

`statusbar-theme` is an interactive theme picker included with statusbar.
**Start `statusbar` first**, then open the picker inside that session:

| Installation | Open the bundled themes |
| --- | --- |
| Homebrew | `statusbar-theme` |
| Release tarball, from its extracted directory | `./bin/statusbar-theme ./themes` |
| Source build, from the repository directory | `./zig-out/bin/statusbar-theme ./zig-out/share/statusbar/themes` |

Use arrows or `j`/`k` to select a theme, then **Enter** to apply it. The
picker stays open so you can try others. Press **Esc** or **q** to close it
and keep the last applied theme.

Applying a theme changes only the current session. **To use it every time**,
run the copy command the picker prints when you exit after changing themes.

Homebrew builds find their bundled themes automatically. You can also pass
a directory of your own `.statusbar` themes:

```sh
statusbar-theme ~/.config/statusbar/themes
```

Bundled themes follow your terminal's palette by default. Choose a
`*-color.statusbar` variant for the original Starship-inspired colors and layouts. See [sample themes](samples/themes/README.md).
The picker uses [zooi](https://github.com/vrypan/zooi).

## Make it yours

The [user guide](docs/README.md) walks through a small config, live updates,
modules, and shell integration. Inside a running session, try a temporary
line for a build (from a project with a Makefile):

```sh
statusbar new build -- make
statusbar remove build
```

Use [Starship integration](docs/starship.md) to move prompt details into the
bar, or add a clock, disk usage, weather, and other features from the
[module library](samples/modules/README.md).

## More examples and details

The [user guide](docs/README.md) covers layouts, live updates, and themes.
See [configuration](docs/config.md), [changing lines](docs/set.md),
[temporary lines](docs/push.md), [listing lines](docs/list.md), [FIFOs](docs/bind.md), or
[how statusbar works](docs/internals.md)
when you need more detail. The guide also covers [shell completions](docs/usage.md#completion).

## How I use statusbar

[My everyday setup](docs/how-i-use-statusbar.md): a minimal Starship statusbar in
every Ghostty terminal, and an `sbx` alias to load a richer statusbar where I'm
spending time.
