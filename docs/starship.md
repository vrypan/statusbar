# Use statusbar with Starship

[Starship](https://starship.rs) can move its prompt details into statusbar.
The terminal keeps only the prompt character:

```
❯ git status
…
❯
statusbar on main [!⇡] via v0.16.0                             18:34
```

## Zsh

Add one line to `~/.zshrc`:

```zsh
eval "$(statusbar init zsh)"
```

Initialization also reports your working directory with OSC 7, allowing
statusbar to update the terminal title. Add `--report-cwd=false` if another
integration already reports it. Both features default to enabled; use
`--starship=false` to keep only directory reporting.

By default the prompt details go to slot 3, the left side of line 2. Select
another slot, including a right-side slot, with:

```zsh
eval "$(statusbar init zsh --starship-slot 5)"
```

There is nothing to change in `starship.toml`. Inside a statusbar session,
each prompt runs Starship as usual and splits the result: every line but the
last goes to statusbar's left slot, and the last line (with Starship's default
layout, the prompt character) stays in the terminal. The character still
turns red after a failed command and follows vi keymaps.

- The line can go before or after `eval "$(starship init zsh)"`; the
  integration takes over the prompt at the first prompt, after `.zshrc` has
  run.
- Outside statusbar, `statusbar init zsh` prints nothing, so the same
  `.zshrc` works in every terminal.
- A one-line Starship prompt is left whole in the terminal, and statusbar keeps
  its configured content.
- If the selected slot is not present, the complete Starship prompt stays in
  the terminal. The integration starts moving its details automatically when
  a configuration loaded later adds that slot.
- Starship's `add_newline` blank line stays in the terminal, above the
  prompt, as it would without statusbar.
- Statusbar's right slot, and the right prompt (`right_format`), are untouched.

Run `statusbar init zsh` inside a session to read the code it installs.

## Fish

Fish has a native prompt function, so it does not need Bash-style command
traps. In `~/.config/fish/config.fish`, initialize Starship first, then let
statusbar replace its left prompt with a splitter:

```fish
starship init fish | source
statusbar init fish | source
```

The same `--starship-slot N` option selects another slot:

```fish
statusbar init fish --starship-slot 5 | source
```

The integration keeps Starship's final prompt line and moves preceding lines
to statusbar. Starship's right prompt remains untouched. Bash is not supported
for prompt relocation; see the [user guide](README.md#put-live-context-in-a-slot)
for a simple Bash slot hook instead.

## Nushell

Copy [samples/statusbar.nu](../samples/statusbar.nu) to
`~/.config/nushell/statusbar.nu`, then add this line to
`~/.config/nushell/config.nu`:

```nu
source ~/.config/nushell/statusbar.nu
```

Start a new shell. The sourced file checks for a statusbar session, so it does
nothing in ordinary Nushell sessions. To use another slot, edit the `set 3`
command in the sample. If another integration already emits OSC 7, remove the
`pre_prompt` hook block from the sample. To keep only directory reporting,
remove the Starship block.

Nushell's prompt closure sends every Starship line except the last to the
selected slot, leaving the final line and Starship's optional leading blank
line in the terminal. It also initializes Starship's right prompt and emits
OSC 7 before each prompt. You do not need to source `starship init nu` separately.
If you already source it, put the statusbar source line after it so statusbar's
left prompt closure takes effect.

## Formatting

Everything comes from the same `starship.toml`, so module settings apply to
both statusbar and the normal prompt. For example, the working directory is the
`directory` module:

```toml
[directory]
truncation_length = 2          # last two directories
truncation_symbol = "…/"
truncate_to_repo  = true       # inside a repository, start at its root
style = "blue bold"
```

Run `starship print-config directory` to see every option and its current
value, or the [starship configuration docs](https://starship.rs/config/) for
all modules.

To style statusbar differently from the prompt, run the hook's
`starship prompt` with its own config file:
`STARSHIP_CONFIG=~/.config/starship-bar.toml STARSHIP_SHELL= starship prompt …`.

Starship's colors pass through to statusbar as they are. The rest of statusbar
(the config's other slot, the rule line) is styled by statusbar's own config;
see [config.md](config.md).

## Troubleshooting

**`%{` or `\[` in statusbar.** The hook is missing `STARSHIP_SHELL=`.

**Statusbar shows the `❯` line, or is empty.** Your `format` doesn't end in
`$line_break$character`, so the last line isn't just the prompt character.
Set up the split by hand with a profile, as in
[Choosing what goes in statusbar](#choosing-what-goes-in-statusbar).

**Nothing reaches statusbar.** Check that `$STATUSBAR_STATE` is set in the
session, that `statusbar init zsh` prints code there, and that
`statusbar set 3 test` shows `test`. A statusbar started before you
updated it may need a restart.

**The right side is misaligned.** statusbar counts most wide characters and
emoji as two cells, but a terminal may draw a symbol at a different width
than statusbar measures. Starship's Nerd Font symbols are counted as one
cell. If a module's symbol throws off alignment, change it in that module's
`symbol` setting.

## Doing it by hand

The sections below build the same thing from parts, for when you want a
different split: another selection of modules, the right slot, or a
profile. Use them instead of `statusbar init zsh`, not together with it. Both
pieces go in `~/.zshrc` after `eval "$(starship init zsh)"`. The prompt
replacement checks `$STATUSBAR_STATE`, and `statusbar set` does nothing outside
a session, so the same `.zshrc` works everywhere.

1. A hook that sends Starship's output to statusbar before each prompt.
2. A shorter `PROMPT` while inside statusbar, so the same details don't
   show twice.

### 1. Send the prompt to statusbar

```zsh
statusbar_precmd() {
  local out
  out=$(STARSHIP_SHELL= starship prompt \
    --terminal-width="$COLUMNS" --jobs="$STARSHIP_JOBS_COUNT" \
    --status="${STARSHIP_CMD_STATUS:-}" --cmd-duration="${STARSHIP_DURATION:-}")
  statusbar set 3 "${out%$'\n'*}"     # drop the last line: ❯
}
precmd_functions+=(statusbar_precmd)
```

- `STARSHIP_SHELL=` is required. In a zsh session starship wraps every color
  code in `%{…%}` for zsh's prompt, and those markers would show up as
  literal text in statusbar.
- `$?` is already overwritten when this hook runs. Starship's own hook,
  which runs first, keeps the exit status and duration in
  `STARSHIP_CMD_STATUS` and `STARSHIP_DURATION`, so the `status` and
  `cmd_duration` modules still work.
- `${out%$'\n'*}` removes the last line of the prompt. With starship's
  default layout, `$all` ends in `$line_break$character`, so that line is the
  prompt character. The newline Starship adds before the prompt
  (`add_newline`) is trimmed by statusbar.
- `statusbar set` does nothing outside a statusbar session, so the hook needs
  no check of its own.

Use an even slot, such as `statusbar set 4`, to put the prompt on the right.

#### Choosing what goes in statusbar

If your `format` doesn't end in `$line_break$character`, or you want a
different selection than the prompt, define a profile and use it instead of
cutting lines:

```toml
# ~/.config/starship.toml
[profiles]
statusbar = "$directory$git_branch$git_status$cmd_duration$status"
```

```zsh
  out=$(STARSHIP_SHELL= starship prompt --profile statusbar \
    --terminal-width="$COLUMNS" --jobs="$STARSHIP_JOBS_COUNT" \
    --status="${STARSHIP_CMD_STATUS:-}" --cmd-duration="${STARSHIP_DURATION:-}")
  statusbar set 3 "$out"
```

A profile is only a format string; modules keep their settings from the rest
of the file.

### 2. Keep only the prompt character in the terminal

Add a profile for the terminal prompt. `[profiles]` may appear only once in
the file, so add the line to an existing section if you have one:

```toml
# ~/.config/starship.toml
[profiles]
statusbar_prompt = "$character"
```

Then switch `PROMPT` to it inside statusbar:

```zsh
if [[ -n $STATUSBAR_STATE ]]; then
  PROMPT='$(starship prompt --profile statusbar_prompt --terminal-width="$COLUMNS" --keymap="${KEYMAP:-}" --status="${STARSHIP_CMD_STATUS:-}" --pipestatus="${STARSHIP_PIPE_STATUS[*]:-}" --cmd-duration="${STARSHIP_DURATION:-}" --jobs="$STARSHIP_JOBS_COUNT")'
fi
```

This is starship's own `PROMPT` line from `starship init zsh`, with
`--profile statusbar_prompt` added. Keeping the other flags keeps the
character red after a failed command and in step with vi keymaps. Do not add
`STARSHIP_SHELL=` here: inside `PROMPT`, zsh needs starship's `%{…%}` markers.

If other modules share the last line of your `format`, such as an
`${env_var.NAME}` indicator before `$character`, put them in this profile too.

The blank line above each prompt comes from starship's `add_newline`. Set
`add_newline = false` at the top of `starship.toml` to remove it; that also
applies outside statusbar.
