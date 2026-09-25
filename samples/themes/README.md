# Theme alternatives

These themes offer different looks for the same useful baseline: user, host,
load, weather, date, and a clock with seconds. They keep the original command
refresh intervals and remove the duplicate load reading on the right.

| Config | Appearance |
| --- | --- |
| pure.config | Transparent background, blue host, purple clock, muted divider |
| tokyo-night.config | Dark blue background, blue badges, half-block border |
| gruvbox.config | Warm orange/yellow/aqua rounded Powerline segments |
| pastel-powerline.config | Purple/rose/peach segments with Powerline arrows |

These are statusbar adaptations inspired by the linked Starship presets,
not Starship configuration files. Starship is not required. Gruvbox and
Pastel need Powerline glyphs, usually provided by a Nerd Font; Pure and Tokyo
Night introduce no special font requirement beyond ordinary Unicode. Existing
weather symbols still depend on your terminal's font fallback.

From the repository root, try one in a fresh terminal outside an existing
statusbar session:

```sh
./zig-out/bin/statusbar --config "$PWD/samples/themes/tokyo-night.config"
```

Replace the filename to compare alternatives. Exit the child shell to return.
No active config has been replaced.

If your shell enables statusbar's Starship integration, Starship may replace a
left slot with its own content and colors. For an isolated preview using Zsh
without startup files:

```sh
./zig-out/bin/statusbar --config "$PWD/samples/themes/tokyo-night.config" -- /bin/zsh -f
```

All variants define two rows. Their rules fill unused space and can frame left
and right labels on the same row. On narrow terminals the right side clips
first. Weather uses the original wttr.in command and may remain empty until
it responds; these themes do not change that network behavior.
Each variant also styles temporary rows created by `statusbar push` through
`[line.push]`. Its `left` template adds a stream marker; its `right` template
formats the tag and ID with the same accent and shapes as the theme's clock.

Inspiration:
- https://starship.rs/presets/pure-preset
- https://starship.rs/presets/tokyo-night
- https://starship.rs/presets/gruvbox-rainbow
- https://starship.rs/presets/pastel-powerline
