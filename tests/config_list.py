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


assert "line.prompt" in run("--list", "default")
run("--list", code=2)
run("--list", "invalid", code=2)
run("--list", "default", "extra", code=2)
for option in ("--print", "--default", "--path", "--check=file", "--add", "--remove=x"):
    run("--list", option, code=2)

with tempfile.TemporaryDirectory(prefix="statusbar-config-list-") as directory:
    state = Path(directory) / "state"
    marker = Path(directory) / "command-must-not-run"
    startup = b"# original comment\n[line.original]\n"
    current = (
        "[line.updated]\ndefault = #(command:test.run)\n"
        "text = #(value)\ntext .= #(fill:-)\n"
        f"[command.test.run]\nrun = touch '{marker}'\n"
    ).encode()
    token = "0123456789abcdef0123456789abcdef"
    state.write_bytes(
        f"statusbar-state 3\nsession {token}\nstartup {len(startup)}\n"
        f"current {len(current)}\n".encode() + startup + current
    )
    env.update(STATUSBAR_STATE=str(state), STATUSBAR_SESSION_ID=token)
    report = run("--list")
    assert "(no prefix) line.updated\n" in report and "test command.test.run\n" in report
    assert "(no prefix) line.original\n" in run("--list", "startup")
    assert run("--print", "current") == current.decode()
    assert run("--print", "startup") == startup.decode()
    assert not marker.exists()
    env["STATUSBAR_SESSION_ID"] = "f" * 32
    run("--list", code=1)
    env["STATUSBAR_SESSION_ID"] = token
    state.unlink()
    run("--list", code=1)

print("config list: passed")
