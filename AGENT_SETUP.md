# Agent guide: set up statusbar and create a personal theme

Use this guide with someone who has installed statusbar. Create a config they
own, configure their shell, and verify their chosen launch method. Use the
installed version's `statusbar --help` and `statusbar COMMAND --help` when an
option differs from this guide.

## 1. Inspect the setup and choose the scope

Locate `statusbar` and `statusbar-theme` with `command -v`, then check
`statusbar --version`. Identify the user's actual terminal and interactive
shell; the agent's shell and `$SHELL` alone may not identify either correctly.
Read the relevant config files, existing statusbar hooks, and launch commands.
Preserve existing settings and save a backup before changing a user file.

Ask only for preferences that are still unknown:

- What should the bar show, and how many lines should it use?
- Should colors follow the terminal theme or use fixed colors?
- If they use Starship, should its prompt details move into the bar?
- **Should statusbar appear in every new tab/window of this terminal, in
  every interactive shell, or only when started manually?**

Configure shell integration for all three launch choices. Automatic launch
is a separate setting: a terminal command affects that terminal's new tabs
and windows; a shell startup block affects other terminals and sessions that
read the same startup file too.

Run `statusbar config --path` to find the config a new session would select,
or `built-in`. Selection follows this order:

1. An explicit `statusbar --config PATH` launch option.
2. `$STATUSBAR_CONFIG`.
3. `$XDG_CONFIG_HOME/statusbar/config` if set; otherwise
   `~/.config/statusbar/config`.

`--path` does not recover a running session's `--config` argument. A missing
file at the default location uses the built-in config; a missing explicit
file is an error. Inside a session, `statusbar config --print current` and
`statusbar config --print startup` show the active and original configs.
These snapshots exclude temporary slot overrides.

Locate bundled themes:

| Installation | Theme directory |
| --- | --- |
| Homebrew | `$(brew --prefix statusbar)/share/statusbar/themes` |
| Release tarball | `themes/` beside `bin/` in the extracted directory |
| Default `zig build` | `zig-out/share/statusbar/themes` |

## 2. Draft the theme

Create a draft in a user-owned directory, for example
`~/.config/statusbar/themes/my-theme.config`, creating its parent if needed.
Copy a suitable bundled theme or use `statusbar config --default` as a
starting point. Prefer a `-native.config` sample for terminal palette colors.
Installed themes may be replaced on upgrade, so customize the copy.

Inspect commands before loading a theme: `#(command)` and `[command.NAME]`
execute shell commands. Include network requests, authenticated `gh` calls,
and other dependencies only when they serve features the user wants. Check
that each command works on their OS.

This small theme uses the terminal palette and needs no network access:

```ini
[colors]
accent = colour12
muted = colour8

[line.1]
rule = ─
style = fg=muted,dim

[line.2]
left = " #[fg=accent,bold]#(host)#[default] "
right = " %a %d %b  %H:%M "

[command.host]
run = hostname
interval = 60
```

Keep these rules in mind:

- **Layout:** `[line.N]` sections must be consecutive from 1. Each supports
  `left`, `right`, `rule`, and `style`. Slots count left then right: line 1
  uses 1 and 2; line 2 uses 3 and 4. The right side clips first on narrow
  terminals. Reserve a slot for each shell hook so it does not overwrite
  another feature.
- **Colors:** `colour0`–`colour15` follow the terminal's palette; `#rrggbb`
  fixes a color. `default` uses the terminal's foreground for `fg` and its
  background for `bg`. Use `[colors]` names in styles and markup. Ghostty's
  palette entry 7 maps to `colour7`; cursor colors have no native alias.
- **Styling:** `#[fg=accent,bold]text#[default]` styles text; `#[default]`
  restores the line's style. Use `dim` for subtle rules and `#[nodim]` for
  text on the same line. Check glyph alignment and contrast in the actual
  font. Powerline layouts may need a Nerd Font.
- **Templates:** `%H:%M` is a clock; `%%` is a literal percent sign. `#(NAME)`
  uses a matching `[command.NAME]`; otherwise its contents run as a shell
  command. Quote values to retain edge spaces. Put comments on their own
  lines, not after values.
- **Commands:** They run with `/bin/sh -c` in statusbar's starting directory,
  with the inherited environment, not the interactive shell's aliases or
  functions. Only their first output line is displayed; stderr is discarded.
  Prefer named commands with an appropriate `interval`. Use a shell hook
  and `statusbar set SLOT TEXT` for data that must follow the shell's `cd`.
- **Starship:** The default destination is slot 3. Leave that slot available
  if using prompt relocation. A one-line Starship prompt stays in the
  terminal; multiline prompts move all but the final line into the bar.
  Starship keeps its own colors even with a native statusbar theme.
- **Temporary lines:** Keep `[line.push]` and its completion sections when
  the user wants the sample's styling for `statusbar push`.

For more options, consult the
[configuration reference](https://github.com/vrypan/statusbar/blob/main/docs/config.md).

## 3. Configure shell integration, including manual launches

Update the startup file the user's interactive shell actually reads. Adapt
existing hooks rather than adding duplicates. Ensure statusbar is on `PATH`
before the hook runs, or use a stable absolute binary path.

| Shell | Startup file |
| --- | --- |
| Zsh | `~/.zshrc`, or the user's `$ZDOTDIR/.zshrc` |
| Fish | `$XDG_CONFIG_HOME/fish/config.fish`, normally `~/.config/fish/config.fish` |
| Bash | `~/.bashrc`; check that the login startup file sources it when needed |

For startup details, see the
[Zsh startup rules](https://zsh.sourceforge.io/Doc/Release/Files.html),
[Fish configuration rules](https://fishshell.com/docs/current/language.html#configuration-files),
and [Bash startup rules](https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html).

### Zsh and Fish

`statusbar init` installs hooks when a shell starts inside statusbar and
prints nothing outside a session. It works whether statusbar was started
manually or automatically. The following examples enable directory reporting
while preserving the user's prompt:

```zsh
# In the user's .zshrc:
eval "$(statusbar init zsh --starship=false)"
```

```fish
# In the user's config.fish:
if status is-interactive
    statusbar init fish --starship=false | source
end
```

Choose the flags for the user's setup:

- Remove `--starship=false` only if they want Starship prompt relocation.
  Initialize Starship normally; for Fish, place statusbar's hook after
  `starship init fish | source`. Use `--starship-slot N` for a destination
  other than slot 3; it cannot be combined with `--starship=false`.
- Add `--report-cwd=false` if the terminal's integration already emits OSC 7
  working-directory reports **inside the statusbar child shell**. This
  includes Ghostty with working shell integration; see the next section.
  Otherwise keep reporting enabled. If both features are disabled, `init`
  prints nothing.

Directory reporting lets statusbar update the terminal title. It does not
change the working directory of configured commands. Verify reporting in a
new statusbar session, since integration active in the parent shell may not
be active in the child. More detail:
[Starship and shell integration](https://github.com/vrypan/statusbar/blob/main/docs/starship.md).

### Bash

There is no `statusbar init bash`. Keep the existing prompt and terminal
integration. When the theme needs data from the interactive shell, add a
prompt hook even for manual launches. For example, **only if slot 1 is
reserved for the directory**:

```bash
__statusbar_cwd() {
    local previous_status=$?
    statusbar set 1 -- "${PWD//#/##}"
    return "$previous_status"
}
```

The substitution escapes `#` for statusbar markup. Register the function once
through the existing prompt framework. If `PROMPT_COMMAND` is unset, use
`PROMPT_COMMAND=__statusbar_cwd`; if it is a string, append the function call
on a new line; if it is an array, append an element. Preserve existing
callbacks and the command exit status used by the prompt. See
[Bash's PROMPT_COMMAND rules](https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html#index-PROMPT_005fCOMMAND).
`statusbar set` does nothing outside a session. A Bash theme without shell
data needs no additional prompt hook.

## 4. Configure the chosen launch method

For manual use, run `statusbar`; it starts `$SHELL`. To select a different
shell or retain login-shell startup behavior, use an explicit command such
as `statusbar -- /bin/zsh -l`. Exit that child shell to return.

For automatic use, choose one launch path below. Replace example binary and
shell paths with the actual installation paths; preserve login flags when
needed. Use a stable path such as Homebrew's `bin/statusbar` symlink, not a
versioned Cellar path. Test the command interactively before saving it.

### Ghostty: every tab and window

Edit the config Ghostty actually loads. The XDG location is
`$XDG_CONFIG_HOME/ghostty/` (normally `~/.config/ghostty/`); macOS also reads
`~/Library/Application Support/com.mitchellh.ghostty/`. The filename is
`config.ghostty` in newer versions or `config` in older ones. Account for
included files and later overrides. See
[Ghostty's config locations](https://ghostty.org/docs/config).

For Zsh:

```ini
command = /absolute/path/to/statusbar -- /bin/zsh -l
shell-integration = zsh
```

Explicitly selecting the shell lets Ghostty inject its integration when the
launch command is statusbar. Select `fish` instead for a Fish child shell.
`command` applies to new windows, tabs, and splits; `initial-command` affects
only the first surface. Preserve existing `shell-integration-features`.
See [Ghostty's options](https://ghostty.org/docs/config/reference).

When this integration reports directories in the child shell, set
`--report-cwd=false` on the shell hook from section 3. For example, **with
Starship relocation enabled**, use:

```zsh
eval "$(statusbar init zsh --report-cwd=false)"
```

For Fish, use `statusbar init fish --report-cwd=false | source` after
Starship's initialization. Keep `--starship=false` too if relocation is
unwanted. Apply the same reporting rule for manual launches; check the
child shell instead of assuming injection was inherited. See
[Ghostty shell integration](https://ghostty.org/docs/features/shell-integration).

### WezTerm and other terminals

In WezTerm's existing Lua config, adapt the returned config table:

```lua
config.default_prog = { '/absolute/path/to/statusbar', '--', '/bin/zsh', '-l' }
```

This selects the program used when no explicit program was supplied. Preserve
the rest of the Lua configuration. See
[WezTerm's default_prog](https://wezterm.org/config/lua/config/default_prog.html).

Kitty also injects shell integration, including directory reporting. Check
its [shell integration instructions](https://sw.kovidgoyal.net/kitty/shell-integration/)
before replacing the launch command with a wrapper. If automatic injection
no longer reaches the child shell, configure the documented manual integration.
A shell startup launch block also needs this check.

For iTerm2, Terminal.app, and other terminals, inspect their profile's launch
command and integration settings. Use a profile command or the shell startup
method below according to the chosen scope. Apply the directory-reporting
rule from section 3 and verify prompt marks and new-tab directory inheritance.

### Automatic launch from shell startup

Use this only if the user chose to start statusbar from interactive shell
startup. Place one block in the startup file identified in section 3. These
examples use `$SHELL`; supply an explicit child command if it differs from
the intended shell or needs login flags.

```zsh
if [[ -o interactive && -t 0 && -t 1 && -z ${STATUSBAR_SESSION_ID:-} ]]; then
    exec statusbar
fi
```

```fish
if status is-interactive; and isatty stdin; and isatty stdout; and not set -q STATUSBAR_SESSION_ID
    exec statusbar
end
```

```bash
if [[ $- == *i* && -t 0 && -t 1 && -z ${STATUSBAR_SESSION_ID:-} ]]; then
    exec statusbar
fi
```

The session guard prevents recursion in the child shell. The terminal checks
avoid launching into redirected input or output. Keep one launch block even
if a Bash login file also sources `.bashrc`. Place it after required `PATH`
setup. Open a new terminal to test startup rather than sourcing the entire
startup file into the current session.

## 5. Preview, save, and verify

Run live updates from a terminal connected to the intended statusbar session.
If the agent's command runner has a separate terminal, ask the user to run
the preview in the intended session. Report visual results only when observed.

Save a copy of `statusbar config --print current` before replacing a live
layout. Then preview:

```sh
statusbar config < ~/.config/statusbar/themes/my-theme.config
```

Outside a session, launch `statusbar --config /absolute/path/to/my-theme.config`
in an interactive terminal. Both methods execute the draft's commands.
The live command validates and sends the config; a zero exit status confirms
sending, not that the session applied it. Check the bar and
`statusbar config --print current` afterward. Invalid configs leave the
active layout intact.

Existing `statusbar set` overrides survive replacement when their slots still
exist. If one hides the draft, clear that specific override with
`statusbar set N`; an active prompt hook may write it again at the next prompt.
The saved config does not include these overrides.

For interactive browsing, use `statusbar-theme /path/to/themes` inside a
session. Homebrew builds default to their bundled directory. Enter applies a
theme and keeps the picker open; `q` or Esc exits with the last selection
active. Its printed copy command is a suggestion, not an automatic save.

After a successful preview, copy the draft to the startup destination found
in section 1, preserving the existing file first. For the usual location:

```sh
mkdir -p ~/.config/statusbar
cp ~/.config/statusbar/themes/my-theme.config ~/.config/statusbar/config
```

Respect `$STATUSBAR_CONFIG`, `$XDG_CONFIG_HOME`, and any explicit `--config`
launch option. For `--config -`, update the source that supplies stdin.
To undo, restore the saved config and startup files; a live preview can be
undone by loading the saved session snapshot.

Verify in a fresh terminal:

- Automatic launch appears once; for manual use, start statusbar yourself.
- The saved theme loads, commands return useful output, and the layout works
  at normal and narrow widths.
- Changing directories updates the intended title or slots. Existing prompt
  behavior and terminal integration still work; Starship uses its reserved
  slot and shows command failures correctly.
- Native colors and glyphs look right. Restart statusbar after switching
  terminal themes to refresh the color cache used for change highlights.

Finish by listing the files changed, the launch method, theme features and
dependencies, checks performed, and how to change or undo the setup. Clearly
identify any visual or terminal behavior that still needs user verification.
