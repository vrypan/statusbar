#!/usr/bin/env python3
"""Inspect saved configs without a PTY or executing configured commands."""
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
for args in ((), ("--debug",)):
    for command in ("list", "ls"):
        run(command, *args, code=2)
        for source in ("default", "current", "startup", "invalid"):
            run(command, *args, source, code=2)
for option in ("--print", "--default", "--path", "--check=file", "--add", "--remove=x", "--list"):
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
        for source in ("default", "current", "startup"):
            run(command, source, code=2)
            run(command, "--debug", source, code=2)
    debug = run("list", "--debug")
    assert debug == run("ls", "--debug")
    for section in ("[global]", "[colors] 1", "[line.updated] #0", "[command] 1", "[push]", "[highlight]"):
        assert section in debug, (section, debug)
    for detail in (
        "  interval = 3000ms\n", '  style = "fg=white"\n', '  accent = "red"\n',
        "  keep = right\n", "  default.text = command:test.run fill:\"-\"\n",
        "  done = style:\"fg=accent\" value\n", "  failed = (empty)\n",
        '    interval = 7000ms\n', '  spinner = 2 frames "a" "b"\n',
        "  running = spinner \" \" value\n", "  pulses = 3\n",
    ):
        assert detail in debug, (detail, debug)
    assert "original" not in debug
    assert run("show") == current.decode()
    assert run("show", "current") == current.decode()
    assert run("show", "startup") == startup.decode()
    assert not marker.exists()
    env["STATUSBAR_SESSION_ID"] = "f" * 32
    run("list", code=1)
    run("list", "--debug", code=1)
    env["STATUSBAR_SESSION_ID"] = token
    state.unlink()
    run("list", code=1)

print("config list: passed")
