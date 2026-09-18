# statusbar

A status bar for any terminal. `statusbar` runs your shell in a smaller pty
and keeps configured rows at the bottom of the window. The bar yields rows
when the terminal is too short. Full-screen programs and scrollback keep
working.

```
❯ make test
…
❯
──────────────────────────────────────────────────────────────────────
 vrypan@vrypan-mbp · load 3.13                   Thu 17 Sep  18:24:31
```

- Configure the bar with templates: text, colors, strftime clocks and shell
  commands, each on its own refresh interval.
- Update it from your scripts with `statusbar set`.
- Move your starship prompt into it with one line in `~/.zshrc`.

![screenshot](screenshot-1.png)

## Build

Requires Zig 0.16 on macOS or Linux.

```sh
zig build -Doptimize=ReleaseSafe      # binary in zig-out/bin/statusbar
zig build test                        # unit tests
```

Or install a released version with Homebrew:

```sh
brew install vrypan/tap/statusbar
```

## Quick start

```sh
# The built-in bar: user, host, load, date and time
statusbar

# Your own, starting from the built-in config
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config
statusbar

# Or from a single command
statusbar -e 'date "+%H:%M"'
```

Run `statusbar --help` for the commands, and `statusbar completion zsh` (or
`bash`, `fish`) for shell completions.

To put starship's prompt in the bar, add this to `~/.zshrc`:

```zsh
eval "$(statusbar init zsh)"
```

## Documentation

Start with the [user guide](docs/README.md): single-command bars, configured
layouts, live slots, Starship, and themes. Detailed references are available
for [configuration](docs/config.md), [runtime slot updates](docs/set.md),
[Starship](docs/starship.md), and [internals and limitations](docs/internals.md).
