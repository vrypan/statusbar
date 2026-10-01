# Change a line

`statusbar set NAME` changes the value or status of an existing line, by name
or by its numeric ID. Only what you supply changes:

| Command | Effect |
|---------|--------|
| `statusbar set build` | nothing |
| `statusbar set build --status running` | the status only |
| `statusbar set build ""` | an explicit empty value |
| `statusbar set build "Build passed" --status success` | value and status together |
| `statusbar set build --reset` | the configured default value; status unchanged |
| `statusbar set build --reset --status normal` | default value and status together |

```sh
statusbar set prompt "$(git branch --show-current)"
statusbar set build "compiling" --status running
statusbar set build --reset
```

A value and a status given together change at once; the bar never shows one
without the other. `--reset` restores the line's `default` (empty if it has
none, or for a pushed line) and cannot be combined with TEXT, not even `""`.
An explicit empty value is not the same as the default: it stays empty after
a config reload, while a line showing its default shows the new default.

Statuses are `normal`, `running`, `done`, `success` and `failed`. Any change
is allowed, from `success` back to `running` too, and none of them changes the
value. The status selects the line's template, so a `failed` line can show a
red cross; see [values and statuses](config.md#values-and-statuses). A line
keeps accepting values whatever its status.

`set` works for configured and [pushed](push.md) lines. Lines hidden because
the terminal is short keep their value and show it when they become visible.
A name that does not exist in the session is an error and never creates a
line. A decimal NAME always means the line with that internal ID, even when
the line also has a name; it never means a position in the bar.

## Values

Words are joined with spaces. Tabs and interior line breaks become spaces,
surrounding line breaks are dropped, and quoted spaces, including an all-space
value, are kept as padding. Values are limited to 1024 bytes.

A value displays as written. `#(value)` in it shows `#(value)`, and
`#[fg=red]` shows `#[fg=red]`: values cannot run expressions or define styles
and tracking. ANSI SGR colors and OSC 8 hyperlinks in a value are kept.
The configured `default` is a template: `--reset` restores its expansion,
including live commands and dates. Setting an empty value suppresses it.
`statusbar set build -` displays a literal dash; use `--` before text that
starts with a dash. To show the latest line of a command's output as it
arrives, use [`statusbar push`](push.md) or a [FIFO](bind.md).

## Outside a session

Outside a statusbar session, a command with valid arguments does nothing and
exits successfully, so shell hooks can call it unconditionally. Invalid
arguments are still reported. Inside a session, an unknown line or a rejected
change prints an error and exits with status 1.

`set` talks to the session over its authenticated control socket, never
through stdout, so it also works from tools that capture command output:

```toml
[custom.statusbar]
command = "statusbar set branch \"$(git branch --show-current)\""
when = true
```

## Update a line at each prompt

A prompt hook can keep a line in sync with the current directory. With a line
such as `[line.cwd]` in your config, add this to `~/.bashrc` for Bash:

```bash
__statusbar_cwd() {
  local previous_status=$?
  statusbar set cwd -- "$PWD"
  return "$previous_status"
}
PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}; }__statusbar_cwd"
```

For Fish, add this to `~/.config/fish/config.fish`:

```fish
function __statusbar_cwd --on-event fish_prompt
  statusbar set cwd -- "$PWD"
end
```

If another prompt framework manages your hooks, add the update through that
framework. For Starship, `statusbar init` does this for you; see
[Starship](starship.md).

## Protocol

`set`, `push`, `pop`, `bind` and [`list`](list.md) send datagrams to a private Unix socket beside
the session's state file (`$STATUSBAR_STATE.sock`). Each request carries the
session token from `$STATUSBAR_SESSION_ID` and is acknowledged. Values travel
base64-encoded, and a request states explicitly whether the value is
unchanged, replaced (possibly with an empty value) or reset, so the session
never guesses from an empty string. The session validates the whole request
before changing anything.

Earlier versions updated numbered slots with an OSC 1337
`SetUserVar=StatusBarSlotN` sequence. statusbar no longer handles it; such
sequences reach the terminal like any other user variable.
