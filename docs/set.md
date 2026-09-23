# Set the text of a slot

Each configured row has two numbered slots:

| Row | Left | Right |
|-----|------|-------|
| 1   | 1    | 2     |
| 2   | 3    | 4     |
| 3   | 5    | 6     |

The pattern continues: row *N* uses slots *2N − 1* and *2N*.

`statusbar set SLOT [TEXT...]` sets the text of a slot. With no text, or a value made
only of CR/LF line breaks, it restores the config or `--exec` value:

```sh
statusbar set 3 "$(git branch --show-current)"
statusbar set 4 "build ✓"
statusbar set 4
```

Slots exist for every desired row, including rows temporarily hidden because
the terminal is short. Updating a hidden slot persists and appears when its
row becomes visible. A slot outside the session's configured range is an
error and never creates another row. Validation uses the session's current
config after an interactive replacement, not its startup row count.

Words are joined with spaces. Tabs and interior line breaks become spaces,
while quoted spaces—including an all-space value—are preserved as padding.
Values are limited to 1024 bytes. Markup and raw SGR colors work in values.
Outside a statusbar session, a syntactically valid command writes nothing and
exits successfully, so shell hooks can call it unconditionally.

The command writes to `/dev/tty`, not stdout, so it also works from tools that
capture command output:

```toml
[custom.statusbar]
command = "statusbar set 4 \"$(git branch --show-current)\""
when = true
```

## The escape sequence

The one-based slot number is part of an iTerm2-style user variable:

```
ESC ] 1337 ; SetUserVar=StatusBarSlotN=<base64> BEL
```

ST (`ESC \\`) also terminates it. For example:

```sh
printf '\e]1337;SetUserVar=StatusBarSlot4=%s\a' "$(printf %s 'build ✓' | base64 | tr -d '\n')"
```

statusbar consumes valid numbered slot variables and drops malformed or
out-of-range variables under its `StatusBar` namespace. It forwards unrelated
OSC sequences and user variables to the terminal. Updates are one-way and
have no acknowledgement.
