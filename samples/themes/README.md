# Personal theme alternatives

Based on the user's current ~/.config/statusbar/config: user, host, load,
weather, date, and a clock with seconds. Commands and refresh intervals are
preserved; the duplicate load reading on the right is removed.

| Config | Appearance |
| --- | --- |
| pure.config | Transparent background, blue host, purple clock, muted divider |
| tokyo-night.config | Dark blue background, blue badges, half-block border |
| gruvbox.config | Warm orange/yellow/aqua segments, heavier divider |
| pastel-powerline.config | Purple/rose/peach segments with Powerline arrows |

These are statusbar adaptations inspired by the linked Starship presets,
not Starship configuration files. Starship is not required. Pastel needs
Powerline glyphs, usually provided by a Nerd Font; the other three introduce
no special font requirement beyond ordinary Unicode. Existing weather
symbols still depend on your terminal's font fallback.

From the repository root, try one in a fresh terminal outside an existing
statusbar session:

```sh
./zig-out/bin/statusbar --config "$PWD/samples/themes/tokyo-night.config"
```

Replace the filename to compare alternatives. Exit the child shell to return.
No active config has been replaced.

If your shell runs `eval "$(statusbar init zsh)"`, Starship may replace the
left slot with its own content and colors. For an isolated preview using zsh
without startup files:

```sh
./zig-out/bin/statusbar --config "$PWD/samples/themes/tokyo-night.config" -- /bin/zsh -f
```

All variants define two rows. Their rules fill unused space and can frame
left and right labels on the same row.
On narrow terminals the right side clips first, as in the existing design.
Weather uses the original wttr.in command and may remain empty until it
responds. These alternatives don't change its network behavior.

Inspiration:
- https://starship.rs/presets/pure-preset
- https://starship.rs/presets/tokyo-night
- https://starship.rs/presets/gruvbox-rainbow
- https://starship.rs/presets/pastel-powerline
