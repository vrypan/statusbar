# Using statusbar with starship

[Starship](https://starship.rs) can move its prompt details into the bar.
The terminal keeps only the prompt character:

```
❯ git status
…
❯
statusbar on main [!⇡] via v0.16.0                             18:34
```

## Setup

Add one line to `~/.zshrc`:

```zsh
eval "$(statusbar init zsh)"
```

That's all; there's nothing to change in `starship.toml`. Inside a statusbar
session, each prompt runs starship as usual and splits the result: every
line but the last goes to the bar's left slot, and the last line (with
starship's default layout, the prompt character) stays in the terminal. The
character still turns red after a failed command and follows vi keymaps.

- The line can go before or after `eval "$(starship init zsh)"`; the
  integration takes over the prompt at the first prompt, after `.zshrc` has
  run.
- Outside statusbar, `statusbar init zsh` prints nothing, so the same
  `.zshrc` works in every terminal.
- A one-line starship prompt is left whole in the terminal, and the bar keeps
  its configured content.
- Starship's `add_newline` blank line stays in the terminal, above the
  prompt, as it would without statusbar.
- The bar's right slot, and the right prompt (`right_format`), are untouched.

Run `statusbar init zsh` inside a session to read the code it installs.

## Doing it by hand

The sections below build the same thing from parts, for when you want a
different split: another selection of modules, the right slot, or a
profile. Use them instead of `statusbar init zsh`, not together with it. Both
pieces go in `~/.zshrc` after `eval "$(starship init zsh)"`, and both check
`$STATUSBAR_LINES`, so the same `.zshrc` works inside and outside statusbar.

1. A hook that sends starship's output to the bar before each prompt.
2. A shorter `PROMPT` while inside statusbar, so the same details don't
   show twice.

### 1. Send the prompt to the bar

```zsh
statusbar_precmd() {
  local out
  out=$(STARSHIP_SHELL= starship prompt \
    --terminal-width="$COLUMNS" --jobs="$STARSHIP_JOBS_COUNT" \
    --status="${STARSHIP_CMD_STATUS:-}" --cmd-duration="${STARSHIP_DURATION:-}")
  statusbar set left "${out%$'\n'*}"     # drop the last line: ❯
}
precmd_functions+=(statusbar_precmd)
```

- `STARSHIP_SHELL=` is required. In a zsh session starship wraps every color
  code in `%{…%}` for zsh's prompt, and those markers would show up as
  literal text in the bar.
- `$?` is already overwritten when this hook runs. Starship's own hook,
  which runs first, keeps the exit status and duration in
  `STARSHIP_CMD_STATUS` and `STARSHIP_DURATION`, so the `status` and
  `cmd_duration` modules still work.
- `${out%$'\n'*}` removes the last line of the prompt. With starship's
  default layout, `$all` ends in `$line_break$character`, so that line is the
  prompt character. The newline starship adds before the prompt
  (`add_newline`) is trimmed by statusbar.
- `statusbar set` does nothing outside a statusbar session, so the hook needs
  no check of its own.

Use `statusbar set right` instead to put the prompt on the right side of the
bar.

#### Choosing what goes in the bar

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
  statusbar set left "$out"
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
if [[ -n $STATUSBAR_LINES ]]; then
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

## Formatting

Everything comes from the same `starship.toml`, so module settings apply to
both the bar and the normal prompt. For example, the working directory is the
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

To style the bar differently from the prompt, run the hook's
`starship prompt` with its own config file:
`STARSHIP_CONFIG=~/.config/starship-bar.toml STARSHIP_SHELL= starship prompt …`.

Starship's colors pass through to the bar as they are. The rest of the bar
(the config's other slot, the rule line) is styled by statusbar's own config;
see the [README](../README.md).

## Troubleshooting

**`%{` or `\[` in the bar.** The hook is missing `STARSHIP_SHELL=`.

**The bar shows the `❯` line, or is empty.** Your `format` doesn't end in
`$line_break$character`, so the last line isn't just the prompt character.
Set up the split by hand with a profile, as in
[Choosing what goes in the bar](#choosing-what-goes-in-the-bar).

**Nothing reaches the bar.** Check that `echo $STATUSBAR_LINES` prints a
number in the session, that `statusbar init zsh` prints code there, and that
`statusbar set left test` shows `test`. A statusbar started before you
updated it may need a restart.

**The right side is misaligned.** statusbar counts most wide characters and
emoji as two cells, but a terminal may draw a symbol at a different width
than statusbar measures. Starship's Nerd Font symbols are counted as one
cell. If a module's symbol throws off alignment, change it in that module's
`symbol` setting.
