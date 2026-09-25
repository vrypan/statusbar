# Set the text of a slot

Each configured line has two numbered slots:

| Line | Left | Right |
|-----|------|-------|
| 1   | 1    | 2     |
| 2   | 3    | 4     |
| 3   | 5    | 6     |

The pattern continues: line *N* uses slots *2N − 1* and *2N*.

`statusbar set SLOT [TEXT...]` sets the text of a slot. With no text, or a value made
only of CR/LF line breaks, it restores the configured value:

```sh
statusbar set 3 "$(git branch --show-current)"
statusbar set 4 "build ✓"
statusbar set 4
```

Slots exist for every desired line, including lines temporarily hidden because
the terminal is short. Updating a hidden slot persists and appears when its
line becomes visible. A slot outside the session's configured range is an
error and never creates another line. Validation uses the session's current
config after an interactive replacement, not its startup line count.

Words are joined with spaces. Tabs and interior line breaks become spaces,
while quoted spaces—including an all-space value—are preserved as padding.
Values are limited to 1024 bytes. Markup and raw SGR colors work in values.
Outside a statusbar session, a syntactically valid command writes nothing and
exits successfully, so shell hooks can call it unconditionally.

`statusbar set 4 -` displays a literal dash. To show the latest line of a
command's output as it arrives, use [`statusbar push`](push.md).

The command writes to `/dev/tty`, not stdout, so it also works from tools that
capture command output:

```toml
[custom.statusbar]
command = "statusbar set 4 \"$(git branch --show-current)\""
when = true
```

## Update a slot at each prompt

A prompt hook can keep a slot in sync with the current directory. For Bash,
add this to `~/.bashrc`:

```bash
__statusbar_cwd() {
  local previous_status=$?
  statusbar set 1 -- "$PWD"
  return "$previous_status"
}
PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}; }__statusbar_cwd"
```

For Fish, add this to `~/.config/fish/config.fish`:

```fish
function __statusbar_cwd --on-event fish_prompt
  statusbar set 1 -- "$PWD"
end
```

These examples use slot 1, the left side of line 1. If another prompt
framework manages your hooks, add the update through that framework.

## The escape sequence

The one-based slot number is part of an iTerm2-style user variable:

```
ESC ] 1337 ; SetUserVar=StatusBarSlotN=<base64> BEL
```

ST (`ESC \\`) also terminates it. For example:

```sh
printf '\e]1337;SetUserVar=StatusBarSlot4=%s\a' "$(printf %s 'build ✓' | base64 | tr -d '\n')"
```

The receiver also accepts `StatusBarSlotLiteralN` in the same OSC envelope for
external senders that need literal text without statusbar markup.

statusbar consumes valid numbered slot variables and drops malformed or
out-of-range variables under its `StatusBar` namespace. It forwards unrelated
OSC sequences and user variables to the terminal. Updates are one-way and
have no acknowledgement.
