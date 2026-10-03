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


# list always shows the current config, so it needs a session and takes no
# source selection.
for args in ((), ("--json",), ("--all", "--json"), ("-a", "--json")):
    for command in ("list", "ls"):
        run(command, *args, code=2)
        for source in ("default", "current", "startup", "invalid"):
            run(command, *args, source, code=2)
for option in ("--print", "--default", "--path", "--check=file", "--add", "--remove=x", "--list", "--debug"):
    run(option, code=2)
    run("list", option, code=2)
run("unknown", code=2)

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
    for command in ("list", "ls"):
        report = run(command)
        assert "(no prefix) line.updated\n" in report and "test command.test.run\n" in report
        assert "line.original" not in report
        assert json.loads(run(command, "--json")) == {
            "version": 1,
            "groups": [
                {"prefix": None, "lines": ["updated"], "commands": []},
                {"prefix": "test", "lines": [], "commands": ["test.run"]},
            ],
        }
        for source in ("default", "current", "startup"):
            run(command, source, code=2)
            run(command, "--json", source, code=2)
    for command in ("list", "ls"):
        for option in ("--all", "-a", "--debug"):
            assert run(command, option, code=2) == ""
        assert run(command, "--debug", "--json", code=2) == ""
    assert run("show") == current.decode()
    assert run("show", "current") == current.decode()
    assert run("show", "startup") == startup.decode()
    assert not marker.exists()
    full_json = run("list", "--all", "--json")
    assert full_json == run("ls", "--json", "--all")
    assert full_json == run("list", "-a", "--json")
    assert full_json == run("ls", "--json", "-a")
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
    grouped_json = run("list", "--json")
    assert grouped_json == run("ls", "--json")
    assert grouped_json.endswith("\n")
    assert json.loads(grouped_json) == {
        "version": 1,
        "groups": [
            {"prefix": None, "lines": ["prompt", "rule"], "commands": ["host"]},
            {"prefix": "a", "lines": ["a.second", "a.first.details"],
             "commands": ["a.second", "a.first"]},
            {"prefix": "only", "lines": [], "commands": ["only.fetch"]},
            {"prefix": "z", "lines": ["z.last"], "commands": ["z.fetch"]},
        ],
    }
    details = json.loads(run("list", "--all", "--json"))
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
    run("list", code=1)
    run("list", "--all", code=2)
    run("list", "--json", code=1)
    run("list", "--all", "--json", code=1)
    env["STATUSBAR_SESSION_ID"] = token
    state.unlink()
    run("list", code=1)
    run("list", "--json", code=1)
    run("list", "--all", "--json", code=1)

print("config list: passed")
