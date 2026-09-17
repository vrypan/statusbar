# Updating the bar from inside a session

Programs running in a statusbar session can replace the left or right slot
of the bar's last text line, meaning the last line that isn't a rule:

```sh
statusbar set left  "$(git branch --show-current)"
statusbar set right "build ✓"
statusbar set right                     # restore the template
```

- Words are joined with spaces, as `echo` would.
- An empty value restores what the config or `--exec` put in the slot.
- Values stay on one line: surrounding line breaks are dropped, and inner
  ones and tabs become spaces.
- [Markup](config.md#markup) and raw SGR colors work in values.
- Outside a statusbar session, the command writes nothing and exits
  successfully, so hooks can call it unconditionally.

The command writes to `/dev/tty`, not stdout, so it also works from tools
that capture a command's output, such as a starship custom module:

```toml
[custom.statusbar]
command = "statusbar set right \"$(git branch --show-current)\""
when    = true
```

Or on every prompt in zsh:

```zsh
statusbar_precmd() { statusbar set right "$(git branch --show-current)"; }
precmd_functions+=(statusbar_precmd)
```

To move starship's whole prompt into the bar, use
[`statusbar init zsh`](starship.md) instead.

## The escape sequence

`statusbar set` sends iTerm2's user-variable sequence, which WezTerm also
understands:

```
ESC ] 1337 ; SetUserVar=StatusBarLeft=<base64> BEL
ESC ] 1337 ; SetUserVar=StatusBarRight=<base64> BEL
```

The value is base64-encoded, so it can hold any bytes. ST (`ESC \`) works as
the terminator too. Any program can send the sequence directly:

```sh
printf '\e]1337;SetUserVar=StatusBarRight=%s\a' "$(printf %s 'build ✓' | base64 | tr -d '\n')"
```

statusbar keeps `StatusBarLeft` and `StatusBarRight` for itself and forwards
every other OSC, including other user variables, to the terminal. Outside
statusbar, terminals ignore the sequence or store it as a user variable.

Anything that can print to the terminal can send these, including a file
shown with `cat` or a remote host over ssh, so treat bar content as
display-only.
