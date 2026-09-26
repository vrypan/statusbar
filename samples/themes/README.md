# Theme alternatives

Each layout has an original version with fixed RGB colors and a `-native`
version that uses the terminal's palette. Native versions keep the same
commands, refresh intervals, and number of lines.

| Original | Terminal palette version | Layout |
| --- | --- | --- |
| [pure.config](pure.config) | [pure-native.config](pure-native.config) | Transparent background, blue host, purple clock, muted divider |
| [tokyo-night.config](tokyo-night.config) | [tokyo-night-native.config](tokyo-night-native.config) | Blue badges and a half-block border |
| [gruvbox.config](gruvbox.config) | [gruvbox-native.config](gruvbox-native.config) | Rounded Powerline segments |
| [pastel-powerline.config](pastel-powerline.config) | [pastel-powerline-native.config](pastel-powerline-native.config) | Multicolored segments with Powerline arrows |
| [minimal.config](minimal.config) | [minimal-native.config](minimal-native.config) | Starship placeholder and a small braille ornament |
| [multi-line.config](multi-line.config) | [multi-line-native.config](multi-line-native.config) | Five lines with Starship space, Hacker News, GitHub notifications, load, and weather |

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

These are statusbar adaptations inspired by the linked Starship presets,
not Starship configuration files. Starship is not required. Gruvbox and
Pastel need Powerline glyphs, usually provided by a Nerd Font; Pure and Tokyo
Night introduce no special font requirement beyond ordinary Unicode. Existing
weather symbols still depend on your terminal's font fallback.

From the repository root, try one in a fresh terminal outside an existing
statusbar session:

```sh
./zig-out/bin/statusbar --config "$PWD/samples/themes/tokyo-night-native.config"
```

Replace the filename to compare alternatives. Exit the child shell to return.
To load a native layout inside an existing statusbar session:

```sh
statusbar config < ./samples/themes/tokyo-night-native.config
```

If your shell enables statusbar's Starship integration, Starship may replace a
left slot with its own content and colors. For an isolated preview using Zsh
without startup files:

```sh
./zig-out/bin/statusbar --config "$PWD/samples/themes/tokyo-night-native.config" -- /bin/zsh -f
```

All layouts except multi-line define two lines; multi-line defines five.
Minimal leaves a placeholder for Starship, and multi-line leaves its second
line's left slot empty. Their rules fill unused space and can frame left
and right labels on the same line. On narrow terminals the right side clips
first. Weather uses the original wttr.in command and may remain empty until
it responds; these themes do not change that network behavior.
Each variant also styles temporary lines created by `statusbar push` through
`[line.push]`. The left side shows a spinner, muted ID, brighter tag, and stream
text. Completion replaces the spinner with a neutral dot, a success checkmark,
or a failure cross. Failed commands show their exit status on the right;
Pastel Powerline and Tokyo Night keep their badge shapes for that label.
See [completion settings](../../docs/config.md#completion-settings) and
[spinners](../../docs/config.md#spinner).

Inspiration:

- https://starship.rs/presets/pure-preset
- https://starship.rs/presets/tokyo-night
- https://starship.rs/presets/gruvbox-rainbow
- https://starship.rs/presets/pastel-powerline
