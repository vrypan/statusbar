# Themes and shared style

Themes use terminal colors by default. Choose a `*-color.statusbar` file for
the original Starship-inspired colors and layouts, including badges and
Powerline segments. Terminal-native themes and modules share muted labels,
dim dotted fills and colored status indicators.

| Terminal palette | Fixed colors | Content |
| --- | --- | --- |
| [minimal.statusbar](minimal.statusbar) | [minimal-color.statusbar](minimal-color.statusbar) | Starship prompt; native uses a separator and `Ready`, color uses a braille ornament and placeholder |
| [pure.statusbar](pure.statusbar) | [pure-color.statusbar](pure-color.statusbar) | Host, load, weather, date and time |
| [tokyo-night.statusbar](tokyo-night.statusbar) | [tokyo-night-color.statusbar](tokyo-night-color.statusbar) | Host, load, weather, date and time |
| [gruvbox.statusbar](gruvbox.statusbar) | [gruvbox-color.statusbar](gruvbox-color.statusbar) | Host, load, weather, date and time |
| [pastel-powerline.statusbar](pastel-powerline.statusbar) | [pastel-powerline-color.statusbar](pastel-powerline-color.statusbar) | Host, load, weather, date and time |
| [multi-line.statusbar](multi-line.statusbar) | [multi-line-color.statusbar](multi-line-color.statusbar) | Prompt, Hacker News, GitHub notifications, load and weather |

The terminal-native versions of Pure, Tokyo Night, Gruvbox and Pastel share
the same layout. Color versions preserve their original formats: Pure uses
restrained colored text, Tokyo Night uses blue badges and a half-block border,
Gruvbox uses rounded segments, and Pastel uses multicolored segments. Gruvbox
Color and Pastel Powerline Color need Powerline glyphs, usually supplied by a
Nerd Font. Native themes need no special font.

Most themes need `curl` for weather. Multi-line also needs `jq` and an
authenticated GitHub CLI. Minimal has no commands or network requirements.
The built-in config shows host, load, date and time without network access.
Add individual features from the [module library](../modules/README.md).

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

From the repository root, try one in a fresh terminal outside an existing
statusbar session:

```sh
./zig-out/bin/statusbar --config "$PWD/samples/themes/tokyo-night.statusbar"
```

Replace the filename to compare alternatives. Exit the child shell to return.
To load a layout inside an existing statusbar session:

```sh
statusbar config load ./samples/themes/tokyo-night.statusbar
```

## Shared styling rules

Use these conventions for terminal-native themes and modules. Color variants
preserve their original palettes and layouts.

- Keep the terminal background. Use muted text at normal intensity for content.
- Start information lines with a bold `* Label: `, followed by a regular-weight value.
- Separate trailing information or fill unused space with dim `·` characters.
  Reset styles before the fill so command output cannot color it.
- Use a dim `─` separator above the bar. Keep the `prompt` line available for
  Starship, which supplies its own colors.
- Reserve accent, success and failure colors for spinners and state indicators.
  Resource meters may use green, yellow and red to show thresholds.
- Put a module's live content in `default` and its label, `#(value)` and fill in
  `text`. Overrides then retain the layout; `update NAME --reset` restores live data.
- Use `keep = left` for temporary lines so their leading name survives clipping.

The built-in config and terminal-native themes define these shared color names:

| Name | Terminal default | Used for |
| --- | --- | --- |
| `text` | `default` | Prompt text |
| `muted` | `colour8` | Labels and ordinary content |
| `rule` | `colour8` | Separators and dotted fills, with `dim` |
| `accent` | `colour3` | Running indicator |
| `success` | `colour10` | Success indicator |
| `failure` | `colour1` | Failure indicator |

Edit these names under `[colors]` to change the whole theme, including module
labels and fills. Color variants retain their original color names; modules
use any matching names and fall back to terminal colors for the rest.
Command output and Starship may supply their own ANSI colors.

Modules use terminal-color fallbacks before shared names:

```ini
[line.example.host]
default = "#(command:example.host)"
text = "#[default,fg=colour8,fg=muted,bold]* Host: #[nobold]#(value) "
text .= "#[default,fg=colour8,fg=rule,dim]#(fill:·)#[default]"

[command.example.host]
run = hostname -s
interval = 3600
```

Style attributes apply in order. With `fg=colour8,fg=muted`, a theme's `muted`
color wins; without that name, the terminal color remains. Modules do not add
shared color definitions, so loading several cannot cause color-name conflicts.
Use a module prefix for any colors specific to that module.

Restart statusbar after changing the terminal theme to refresh the color cache
used by change highlights.

## Prompt, commands and temporary lines

Starship replaces the value of `prompt`; the surrounding clock and weather
remain where the theme provides them. Use `statusbar update prompt --reset` to
restore the fallback. Native themes give temporary lines a spinner, bold
name, muted value and dotted fill, with success and failure indicators.
Color variants retain their original temporary-line styling.

The default config and most themes group commands under `system.*`.
Multi-line also groups news under `hn.*` and notifications under `gh.*`.
Use `statusbar config show --json` to inspect their definitions. A prefix cannot be removed while
remaining definitions reference its commands or colors.
