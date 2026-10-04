# List session lines

Run inside a live statusbar session:

```sh
statusbar list
statusbar list --temp
statusbar list --json
statusbar list --temp --json
```

`statusbar ls` is an alias for `statusbar list`. The default output is a table
with `ID`, `NAME`, `TEMP`, `ACCESS`, `FIFO` and `STATUS` columns. Configured
lines come first in config order, followed by temporary lines in creation
order. Hidden lines are included. `--temp` shows only temporary lines without
changing their order or visibility.

`TEMP` and `FIFO` show `yes` or `no`. `ACCESS` is `rw` when supplied text
appears in the line's current status template, and `ro` otherwise. It describes
whether an override is displayed, not whether the command accepts updates.
An unnamed line has `-` in the `NAME` column. Use JSON to inspect values,
visibility and FIFO paths, or to consume the listing in scripts.

For configuration definitions and compiled templates, use
[`statusbar config show --json`](config.md#inspect-the-parsed-configuration).

## JSON format

```json
{
  "version": 1,
  "lines": [
    {
      "id": 4,
      "name": "build-4",
      "temp": true,
      "access": "rw",
      "status": "running",
      "visible": true,
      "value": "Compiling…",
      "fifo": false,
      "fifo_path": null
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `version` | JSON format version, currently `1` |
| `id` | Stable, never reused within the session; accepted by `update`, `bind` and `remove` |
| `name` | Explicit or generated name, or `null` for an unnamed line |
| `temp` | `true` for a temporary line, `false` for a configured line |
| `access` | `rw` if supplied text appears in the current status template; otherwise `ro` |
| `status` | Display status: `normal`, `running`, `done`, `success` or `failed` |
| `visible` | Whether the current layout gives the line a terminal row |
| `value` | Stored override text, or `null` when no override is set |
| `fifo` | Whether a FIFO is bound to the line |
| `fifo_path` | Bound FIFO path, or `null` when the line has no binding |

An ID passed to `remove` selects the whole group for a dotted line name;
see [removing lines](push.md#remove-lines).

`value` contains no template expansion, padding or clipping. A configured
line with `null` uses its configured default; a temporary line with `null` has
no supplied value. An explicitly empty value is `""`, including when it
suppresses a configured default. ANSI sequences remain part of the value
and are JSON-escaped. Invalid UTF-8 bytes are replaced with U+FFFD in the
snapshot; the session's stored bytes are unchanged.

`fifo` reports bindings created by `bind` or `new --fifo`, including those
on hidden lines. Unbinding makes `fifo` false and `fifo_path` null.

The result is one complete snapshot. A later `update`, `remove`, config
replacement or terminal resize may change what a subsequent call returns.
Listing does not modify lines, statuses or producer ownership.

With no matches, JSON contains `"lines": []`, the table contains only its
header, and the command exits successfully. Missing, stale or incompatible
sessions produce an error on stderr and a nonzero exit status.

## Transport

An authenticated `list` request publishes all lines atomically to a mode-0600
file beside the session state (`$STATUSBAR_STATE.lines`) and acknowledges
its path. The CLI validates the snapshot's session and version, then filters
and formats it. The file avoids Unix datagram size limits, is replaced on
each successful query, and is removed during normal session cleanup.
Concurrent readers always see a complete snapshot, possibly from a newer
query made during their request/read window. Use the CLI to obtain fresh
state; the file is an internal transport, not a continuously updated API.
