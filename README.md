# statusbar

A status bar at the bottom of your terminal. It keeps useful information
visible while you work, without repeating it in every prompt. Your shell,
full-screen programs, and scrollback continue to work.

![screenshot](demo/screenshot.png)

## Install

With Homebrew:

```sh
brew install vrypan/tap/statusbar
```

Or build from source with Zig 0.16 on macOS or Linux:

```sh
zig build -Doptimize=ReleaseSafe
# The binary is zig-out/bin/statusbar
```

## Quick start

If you built from source, use `./zig-out/bin/statusbar` in place of
`statusbar` below.

```sh
# Start your usual shell with the built-in statusbar.
statusbar

# Make a personal config from the built-in one.
mkdir -p ~/.config/statusbar
statusbar config --default > ~/.config/statusbar/config
statusbar
```

Each config line has a left and right side. Add text, a clock, or a command's
output; [the guide](docs/README.md) starts with small examples.

Inside a statusbar session, scripts can set a slot with `statusbar set 1 "Ready"`.
For live output, `statusbar push -t build -- make` adds a temporary line;
`statusbar pop` removes it. You can also move Starship's prompt details into
a statusbar slot.

Run `statusbar --help` for the full command list.

## Use Starship in statusbar

To put Starship's prompt in statusbar, add this to `~/.zshrc`:

```zsh
eval "$(statusbar init zsh)"
```

This moves Starship's information into slot 3 and leaves the prompt character
in the terminal. It also updates the terminal title when you change directory.
[Starship setup](docs/starship.md) covers other slots and options.

Fish uses its native prompt function; put these after one another in
`~/.config/fish/config.fish`:

```fish
starship init fish | source
statusbar init fish | source
```

## More examples and details

The [user guide](docs/README.md) covers layouts, live updates, and themes.
See [configuration](docs/config.md), [slot updates](docs/set.md),
[temporary lines](docs/push.md), or [how statusbar works](docs/internals.md)
when you need more detail. The guide also covers [shell completions](docs/usage.md#completion).

## How I use statusbar

[My everyday setup](docs/how-i-use-statusbar.md): a minimal Starship statusbar in
every Ghostty terminal, and an `sbx` alias to load a richer statusbar where I'm
spending time.
