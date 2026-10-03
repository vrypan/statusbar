# List session lines

Run inside a live statusbar session:

```sh
statusbar list
statusbar list --pushed
statusbar list --json
statusbar list --pushed --json
statusbar list --short
statusbar list --pushed --short --json
```

The default output is a table with `ID`, `NAME`, `KIND`, `STATUS`, `VISIBLE`,
`FIFO` and `VALUE` columns. Configured lines come first in config order,
followed by pushed lines in creation order. Hidden lines are included. `--pushed` shows
only pushed lines without changing their order or visibility.

Use `--short` for a compact table with only `ID`, `NAME`, `STATUS` and
`VALUE`. It combines with `--pushed` and `--json`.

The table uses `-` for an unnamed line or an unbound FIFO, `<default>` for a
value with no override, and `""` for an explicitly empty value. Control characters and
backslashes in values are escaped so they cannot change the terminal or
create extra table rows. Long values are not clipped to the terminal width.
Use JSON for scripts rather than parsing the table.

For configuration definitions grouped by prefix, use
[`statusbar config list`](config.md#inspect-the-parsed-configuration).

## JSON format

```json
{
  "version": 1,
  "lines": [
    {
      "id": 4,
      "name": "pueue-12",
      "kind": "pushed",
      "status": "running",
      "visible": true,
      "value": "Compiling…",
      "fifo": null
    }
  ]
}
```

`--short --json` keeps the same `version` and `lines` envelope, but each
line contains only `id`, `name`, `status` and `value`. Omitted fields are
absent, not set to null; names and values retain their usual null semantics.

| Field | Meaning |
|---|---|
| `version` | JSON format version, currently `1` |
| `id` | Stable, never reused within the session; accepted by `set` and `pop` |
| `name` | Explicit name, or `null` for an unnamed line |
| `kind` | `configured` or `pushed` |
| `status` | Display status: `normal`, `running`, `done`, `success` or `failed` |
| `visible` | Whether the current layout gives the line a terminal row |
| `value` | Stored override text, or `null` when no override is set |
| `fifo` | Bound FIFO path, or `null` when the line has no binding |

`value` contains no template expansion, padding or clipping. A configured
line with `null` uses its configured default; a pushed line with `null` has
no supplied value. An explicitly empty value is `""`, including when it
suppresses a configured default. ANSI sequences remain part of the value
and are JSON-escaped. Invalid UTF-8 bytes are replaced with U+FFFD in the
snapshot; the session's stored bytes are unchanged.

`fifo` reports bindings created by `bind` or `push --fifo`, including those
on hidden lines. Unbinding a line makes its `fifo` field `null`.

The result is one complete snapshot. A later `set`, `pop`, config replacement
or terminal resize may change what a subsequent call returns. Listing does
not modify lines, statuses or producer ownership.

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
