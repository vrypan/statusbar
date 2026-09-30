# Theme alternatives

Each layout has an original version with fixed RGB colors and a `-native`
version that uses the terminal's palette. Native versions keep the same
commands, refresh intervals, and lines.

| Original | Terminal palette version | Layout |
| --- | --- | --- |
| [pure.statusbar](pure.statusbar) | [pure-native.statusbar](pure-native.statusbar) | Transparent background, blue host, purple clock, muted divider |
| [tokyo-night.statusbar](tokyo-night.statusbar) | [tokyo-night-native.statusbar](tokyo-night-native.statusbar) | Blue badges and a half-block border |
| [gruvbox.statusbar](gruvbox.statusbar) | [gruvbox-native.statusbar](gruvbox-native.statusbar) | Rounded Powerline segments |
| [pastel-powerline.statusbar](pastel-powerline.statusbar) | [pastel-powerline-native.statusbar](pastel-powerline-native.statusbar) | Multicolored segments with Powerline arrows |
| [minimal.statusbar](minimal.statusbar) | [minimal-native.statusbar](minimal-native.statusbar) | Starship placeholder and a small braille ornament |
| [multi-line.statusbar](multi-line.statusbar) | [multi-line-native.statusbar](multi-line-native.statusbar) | Five lines with Starship space, Hacker News, GitHub notifications, load, and weather |

Pure, Tokyo Night, Gruvbox, and Pastel Powerline share a baseline of user,
host, load, weather, and a clock. The multi-line sample also needs `jq` and
an authenticated GitHub CLI; see its header for requirements.

## Native colors

Native versions use `colour0` through `colour15` and `default`, so their
colors come from the current terminal theme. This works with Ghostty and
other terminals that support ANSI colors. For example:

```ini
[colors]
text = default
accent = colour3
muted = colour8
success = colour10
failure = colour1
```

`default` means the terminal's foreground when used with `fg`, and its
background when used with `bg`. Native badge and Powerline layouts use that
background for the row, with explicit palette black or white for text on
colored segments. The first 16 palette entries determine the actual hues;
the Gruvbox variant uses red/yellow/cyan, and the Pastel variant uses
magenta/bright magenta/bright yellow/bright blue.

Muted rules use `dim` where appropriate. The multi-line layout clears dim
on its text, keeping the dotted fill softer than the content. Adjust the
named colors in `[colors]` to suit your terminal palette.

Restart statusbar after switching terminal themes to refresh the cached
colors used by change highlights. Starship content uses its own color
configuration; selecting a native statusbar theme does not recolor Starship.

## Try a layout

All twelve configs are bundled with the binaries:

| Installation | Theme directory |
| --- | --- |
| Homebrew | `$(brew --prefix statusbar)/share/statusbar/themes` |
| Release tarball | `themes/` alongside `bin/` |
| `zig build` | `zig-out/share/statusbar/themes` |

For Homebrew, run inside a statusbar session:

```sh
statusbar-theme
```

The Homebrew build uses its bundled theme directory by default; an explicit
directory argument overrides it. Other builds require a directory unless
compiled with `-Ddefault-themes-dir=/path/to/themes`.

Themes installed by Homebrew are package data and may be replaced on upgrade.
Copy a theme to your own directory before customizing it.

Inside a running statusbar session, browse this directory interactively:

```sh
./zig-out/bin/statusbar-theme ./samples/themes
```

The separate `statusbar-theme` binary lists `.statusbar` files alphabetically
in the given directory, including symlinks to regular files. It does not
recurse. Use arrows or `j`/`k`, Page Up/Down, and Home/End to navigate.
Enter validates and applies the selected config while keeping the picker open.
Esc, `q`, or Ctrl-C closes it, leaving the last applied theme active.
After a change, the picker prints a copy command to make the selected theme
your startup config. The destination respects `STATUSBAR_CONFIG` and
`XDG_CONFIG_HOME`, otherwise using `~/.config/statusbar/config.statusbar`. It only
prints the command; run it yourself to save the theme.
Invalid or oversized configs report an error and leave the session unchanged.
Selecting a theme replaces the entire session config, just like
`statusbar config < FILE`, without modifying your saved config. Commands in
the selected config run once it is activated.

These are statusbar adaptations inspired by the linked Starship presets,
not Starship configuration files. Starship is not required. Gruvbox and
Pastel need Powerline glyphs, usually provided by a Nerd Font; Pure and Tokyo
Night introduce no special font requirement beyond ordinary Unicode. Existing
weather symbols still depend on your terminal's font fallback.

From the repository root, try one in a fresh terminal outside an existing
statusbar session:

```sh
./zig-out/bin/statusbar --config "$PWD/samples/themes/tokyo-night-native.statusbar"
```

Replace the filename to compare alternatives. Exit the child shell to return.
To load a native layout inside an existing statusbar session:

```sh
statusbar config < ./samples/themes/tokyo-night-native.statusbar
```

If your shell enables statusbar's Starship integration, Starship's details
become the value of each theme's `prompt` line, in Starship's colors.
In Pure, Tokyo Night, Gruvbox, and Pastel Powerline, that value replaces the
user/host/load fallback; weather and the clock remain on the right.
The fill resets to the theme's base colors after the value.
For an isolated preview using Zsh without startup files:

```sh
./zig-out/bin/statusbar --config "$PWD/samples/themes/tokyo-night-native.statusbar" -- /bin/zsh -f
```

All layouts except multi-line define two lines; multi-line defines five.
Each has a line named `prompt` for Starship: Minimal shows a placeholder
default until Starship replaces it, and multi-line leaves its left side empty.
Fills draw the rules, carry line backgrounds, and separate left and right
labels on the same line. On narrow terminals the right side clips first.
Weather uses the original wttr.in command and may remain empty until it
responds; these themes do not change that network behavior.
Each variant also styles temporary lines created by `statusbar push` through
`[push]`. The line shows a spinner, the line's name, and its latest text.
Its status templates replace the spinner with a neutral dot, a success
checkmark, or a failure cross, and failed commands show `failed` on the
right; Pastel Powerline and Tokyo Night keep their badge shapes for that
label. See [`[push]`](../../docs/config.md#push) and
[spinners](../../docs/config.md#spinner).

Inspiration:

- https://starship.rs/presets/pure-preset
- https://starship.rs/presets/tokyo-night
- https://starship.rs/presets/gruvbox-rainbow
- https://starship.rs/presets/pastel-powerline
