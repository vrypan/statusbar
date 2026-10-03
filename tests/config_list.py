#!/usr/bin/env python3
"""Inspect saved configs without a PTY or executing configured commands."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


binary = str(Path(sys.argv[1]).resolve())
env = dict(os.environ)
env.pop("STATUSBAR_STATE", None)
env.pop("STATUSBAR_SESSION_ID", None)


def run(*args, code=0):
    result = subprocess.run(
        [binary, "config", *args], env=env, input="ignored stdin",
        text=True, capture_output=True, timeout=10,
    )
    assert result.returncode == code, (args, result.returncode, result.stderr)
    return result.stdout


for args in (('show',), ('show', '--json'), ('show', 'startup', '--json')):
    run(*args, code=2)
for command in ('list', 'ls', 'remove', 'rm'):
    run(command, code=2)
for option in ('--print', '--default', '--path', '--check=file', '--add', '--remove=x', '--list', '--debug'):
    run(option, code=2)
run('show', 'path', code=2)
run('show', '--all', '--json', code=2)
run('unknown', code=2)
assert json.loads(run('show', 'default', '--json'))['lines']

# Exercise generated completion rather than assuming registration is enough.
completion = subprocess.check_output([binary, 'completion', 'bash'], text=True)
for words, position, expected in (
    ('statusbar ""', 1, {'run', 'new', 'remove', 'rm', 'list', 'ls', 'update', 'upd', 'bind', 'config', 'init', 'completion'}),
    ('statusbar upd "--"', 2, {'--status', '--reset', '--help'}),
    ('statusbar update "--"', 2, {'--status', '--reset', '--help'}),
    ('statusbar config ""', 2, {'load', 'import', 'check', 'show', 'path'}),
    ('statusbar config show ""', 3, {'current', 'startup', 'default'}),
    ('statusbar remove "-"', 2, {'--all', '-a', '--help', '-h'}),
    ('statusbar rm "-"', 2, {'--all', '-a', '--help', '-h'}),
    ('statusbar list "--"', 2, {'--temp', '--json', '--help'}),
    ('statusbar ls "--"', 2, {'--temp', '--json', '--help'}),
):
    result = subprocess.run(
        ['bash'], input=completion + f'\nCOMP_WORDS=({words}); COMP_CWORD={position}; '
        '_statusbar; printf "%s\\n" "${COMPREPLY[@]}"\n',
        text=True, capture_output=True, check=True,
    )
    assert set(result.stdout.splitlines()) == expected, (words, result.stdout, result.stderr)

with tempfile.TemporaryDirectory(prefix="statusbar-config-list-") as directory:
    state = Path(directory) / "state"
    marker = Path(directory) / "command-must-not-run"
    startup = b"# original comment\n[line.original]\n"
    current = (
        "interval = 3\nstyle = fg=white\n[colors]\naccent = red\n"
        "[line.updated]\ndefault = #(command:test.run)\n"
        "text = #(value)\ntext .= #(fill:-)\n"
        "done = #[fg=accent]#(value)\nfailed = \"\"\nkeep = right\n"
        f"[command.test.run]\nrun = touch '{marker}'\ninterval = 7\n"
        "[push]\nspinner = ab\nrunning = #(spinner) #(value)\n"
        "[highlight]\npulses = 3\n"
    ).encode()
    token = "0123456789abcdef0123456789abcdef"
    state.write_bytes(
        f"statusbar-state 3\nsession {token}\nstartup {len(startup)}\n"
        f"current {len(current)}\n".encode() + startup + current
    )
    env.update(STATUSBAR_STATE=str(state), STATUSBAR_SESSION_ID=token)
    assert run("show") == current.decode()
    assert run("show", "current") == current.decode()
    assert run("show", "startup") == startup.decode()
    assert not marker.exists()
    full_json = run("show", "--json")
    assert full_json == run("show", "current", "--json")
    assert json.loads(run("show", "startup", "--json"))["lines"][0]["name"] == "original"
    assert json.loads(full_json) == {
        "version": 1,
        "global": {"interval_ms": 3000, "style": "fg=white"},
        "colors": [{"name": "accent", "value": "red"}],
        "lines": [{
            "name": "updated", "index": 0, "keep": "right",
            "default": "#(command:test.run)",
            "variants": {
                "text": [{"value": {}}, {"fill": "-"}],
                "running": None, "done": [{"style": "fg=accent"}, {"value": {}}],
                "success": None, "failed": [],
            },
            "default_variants": {
                "text": [{"command": "test.run"}, {"fill": "-"}],
                "running": None, "done": [{"style": "fg=accent"}, {"command": "test.run"}],
                "success": None, "failed": [],
            },
        }],
        "commands": [{"name": "test.run", "index": 0, "run": f"touch '{marker}'",
                      "interval_ms": 7000, "uses_global_interval": False}],
        "push": {
            "keep": "right", "spinner": ["a", "b"], "spinner_interval_ms": 100,
            "variants": {
                "text": [{"value": {}}, {"fill": " "}, {"text": "["}, {"name": {}}, {"text": "]"}],
                "running": [{"spinner": {}}, {"text": " "}, {"value": {}}],
                "done": None, "success": None, "failed": None,
            },
        },
        "highlight": {"pulses": 3},
    }
    # Prefixes sort alphabetically, but full names retain declaration order
    # within each kind. Include a deeper dotted name and a command-only group.
    grouped = (
        "[line.z.last]\n"
        "text = #[track]#(command:a.first)#[notrack] #(terminal:cols) #(env:HOME) #(status) #(name) #(datetime:%H:%M)\n"
        "text .= #(fill:·)\n"
        "[line.prompt]\n[line.a.second]\n"
        "[line.a.first.details]\n[line.rule]\n"
        f"[command.z.fetch]\nrun = touch '{marker}'\n"
        f"[command.a.second]\nrun = touch '{marker}'\n"
        "[command.host]\nrun = true\n[command.a.first]\nrun = true\n"
        "[command.only.fetch]\nrun = true\n"
    ).encode()
    state.write_bytes(
        f"statusbar-state 3\nsession {token}\nstartup {len(startup)}\n"
        f"current {len(grouped)}\n".encode() + startup + grouped
    )
    details = json.loads(run("show", "--json"))
    assert [line["name"] for line in details["lines"]] == ["z.last", "prompt", "a.second", "a.first.details", "rule"]
    assert details["global"] == {"interval_ms": 5000, "style": None}
    assert details["colors"] == []
    assert details["push"]["spinner"] == []
    assert details["highlight"] == {"pulses": 2}
    line = details["lines"][0]
    assert line["default"] == "" and line["default_variants"] is None
    assert line["variants"]["text"] == [
        {"track_start": 0}, {"command": "a.first"}, {"track_end": 0},
        {"text": " "}, {"terminal": "cols"}, {"text": " "}, {"env": "HOME"},
        {"text": " "}, {"status": {}}, {"text": " "}, {"name": {}},
        {"text": " "}, {"datetime": "%H:%M"}, {"fill": "·"},
    ]
    assert all(c["uses_global_interval"] and c["interval_ms"] == 5000 for c in details["commands"])
    assert [c["index"] for c in details["commands"]] == list(range(5))
    assert not marker.exists()
    env["STATUSBAR_SESSION_ID"] = "f" * 32
    run("show", code=1)
    run("show", "--json", code=1)
    env["STATUSBAR_SESSION_ID"] = token
    state.unlink()
    run("show", code=1)
    run("show", "--json", code=1)

print("config show: passed")
