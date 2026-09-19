#!/usr/bin/env python3
"""Deterministic PTY checks for configured rows, resizing, and slot updates."""

import base64
import fcntl
import os
import pty
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


def resize(fd, rows, cols=80):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def read_until(fd, data, needle, timeout=5):
    deadline = time.monotonic() + timeout
    while needle not in data:
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {needle!r}; tail={data[-500:]!r}")
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data += os.read(fd, 65536)
            except OSError:
                break
    return data


def spawn(argv, rows=24, env=None):
    ready_r, ready_w = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.close(ready_w)
        os.read(ready_r, 1)
        os.close(ready_r)
        os.execve(argv[0], argv, env or os.environ)
    os.close(ready_r)
    resize(master, rows)
    os.write(ready_w, b"x")
    os.close(ready_w)
    return pid, master


def capture_pty(argv, env=None, rows=24, timeout=5):
    pid, master = spawn(argv, rows, env)
    data = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            try:
                chunk = os.read(master, 65536)
                if chunk:
                    data += chunk
            except OSError:
                pass
        got, status = os.waitpid(pid, os.WNOHANG)
        if got:
            while True:
                ready, _, _ = select.select([master], [], [], 0)
                if not ready:
                    break
                try:
                    chunk = os.read(master, 65536)
                    if not chunk:
                        break
                    data += chunk
                except OSError:
                    break
            os.close(master)
            return os.waitstatus_to_exitcode(status), data
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    os.close(master)
    raise AssertionError(f"timed out running {argv!r}; tail={data[-500:]!r}")


def osc_value(data, slot):
    prefix = f"\x1b]1337;SetUserVar=StatusBarSlot{slot}=".encode()
    start = data.find(prefix)
    if start < 0:
        raise AssertionError(f"slot {slot} update missing from {data!r}")
    start += len(prefix)
    end = data.find(b"\x07", start)
    if end < 0:
        raise AssertionError("unterminated slot update")
    return base64.b64decode(data[start:end])


def check_zsh(binary):
    zsh = shutil.which("zsh")
    if zsh is None:
        print("zsh -f integration skipped: zsh unavailable")
        return

    env = os.environ.copy()
    env["STATUSBAR_LINES"] = "3"
    quoted_binary = shlex.quote(binary)
    for bad in ("+1", "-1", "zero", "0", "999999999999999999999999999999"):
        result = subprocess.run(
            [binary, "init", "zsh", "--starship-slot", bad],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert result.returncode == 2, (bad, result)
        assert result.stdout == b"", (bad, result.stdout)

    invalid_env = env.copy()
    invalid_env["STATUSBAR_LINES"] = "1"
    invalid = subprocess.run(
        [binary, "init", "zsh"], env=invalid_env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    assert invalid.returncode == 2
    assert invalid.stdout == b"", "invalid init must not replace the prompt"

    zero_env = env.copy()
    zero_env["STATUSBAR_LINES"] = "0"
    zero = subprocess.run(
        [binary, "init", "zsh", "--starship-slot", "1"], env=zero_env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    assert zero.returncode == 2
    assert zero.stdout == b""
    assert b"STATUSBAR_LINES is malformed" in zero.stderr

    with tempfile.TemporaryDirectory() as directory:
        starship = os.path.join(directory, "starship")
        with open(starship, "w", encoding="utf-8") as file:
            file.write("#!/bin/sh\ncase $STARSHIP_TEST_MODE in\n  multi) printf 'bar%%%%literal\\nprompt' ;;\n  one) printf 'one%%%%literal' ;;\nesac\n")
        os.chmod(starship, 0o755)
        zenv = env.copy()
        zenv["PATH"] = directory + os.pathsep + zenv.get("PATH", "")

        for slot, option in ((3, ""), (5, "--starship-slot 5")):
            script = (
                f'export STARSHIP_TEST_MODE=multi; eval "$({quoted_binary} init zsh {option})"; '
                "__statusbar_prompt"
            )
            code, data = capture_pty([zsh, "-f", "-c", script], zenv)
            assert code == 0, data
            assert osc_value(data, slot) == b"bar%literal", data
            assert b"prompt" in data

        script = (
            f'export STARSHIP_TEST_MODE=one; eval "$({quoted_binary} init zsh)"; '
            "__statusbar_prompt"
        )
        code, data = capture_pty([zsh, "-f", "-c", script], zenv)
        assert code == 0, data
        assert b"SetUserVar=StatusBarSlot" not in data
        assert b"one%%literal" in data, data

    print("zsh -f integration passed")


def check_fish(binary):
    fish = shutil.which("fish")
    if fish is None:
        print("fish integration skipped: fish unavailable")
        return

    env = os.environ.copy()
    env["STATUSBAR_LINES"] = "3"
    quoted_binary = shlex.quote(binary)
    with tempfile.TemporaryDirectory() as directory:
        starship = os.path.join(directory, "starship")
        with open(starship, "w", encoding="utf-8") as file:
            file.write("#!/bin/sh\ncase $STARSHIP_TEST_MODE in\n  multi) printf 'bar%%literal\\nprompt' ;;\n  one) printf 'one%%literal' ;;\nesac\n")
        os.chmod(starship, 0o755)
        fenv = env.copy()
        fenv["PATH"] = directory + os.pathsep + fenv.get("PATH", "")

        for slot, option in ((3, ""), (5, "--starship-slot 5")):
            script = (
                f"set -gx STARSHIP_TEST_MODE multi; {quoted_binary} init fish {option} | source; "
                "fish_prompt"
            )
            code, data = capture_pty([fish, "-N", "-c", script], fenv)
            assert code == 0, data
            assert osc_value(data, slot) == b"bar%literal", data
            assert b"prompt" in data

        script = (
            f"set -gx STARSHIP_TEST_MODE one; {quoted_binary} init fish | source; "
            "fish_prompt"
        )
        code, data = capture_pty([fish, "-N", "-c", script], fenv)
        assert code == 0, data
        assert b"SetUserVar=StatusBarSlot" not in data
        assert b"one%literal" in data, data

    print("fish integration passed")


def stop(pid, fd):
    try:
        os.write(fd, b"EXIT\n")
    except OSError:
        pass
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        got, _ = os.waitpid(pid, os.WNOHANG)
        if got:
            os.close(fd)
            return
        time.sleep(0.02)
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    os.close(fd)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: multirow_pty.py STATUSBAR")
    binary = os.path.abspath(sys.argv[1])

    env = os.environ.copy()
    env["STATUSBAR_LINES"] = "1"
    code, data = capture_pty([binary, "set", "1", "   "], env)
    assert code == 0
    assert osc_value(data, 1) == b"   ", data

    invalid_env = os.environ.copy()
    invalid_env["STATUSBAR_LINES"] = "0"
    invalid = subprocess.run(
        [binary, "set", "1", "x"], env=invalid_env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    assert invalid.returncode == 2
    assert b"STATUSBAR_LINES is malformed" in invalid.stderr

    check_zsh(binary)
    check_fish(binary)
    config = """\
[line.1]
left = one
rule = -
[line.2]
left = two
[line.3]
left = three
right = configured-six
"""
    script = r'''
statusbar_bin=$1
trap 'size=$(stty size); rows=${size%% *}; printf "__SIZE__:%s:%s\n" "$rows" "$STATUSBAR_LINES"' WINCH
size=$(stty size); rows=${size%% *}; printf "__START__:%s:%s\n" "$rows" "$STATUSBAR_LINES"
while IFS= read -r command; do
  case "$command" in
    SET) "$statusbar_bin" set 6 hidden-value; printf '__SET__\n' ;;
    BAD) "$statusbar_bin" set 7 bad; printf '__BAD__:%s\n' "$?" ;;
    EXIT) exit 0 ;;
  esac
done
'''
    with tempfile.NamedTemporaryFile("w", delete=False) as cfg:
        cfg.write(config)
        config_path = cfg.name
    pid = master = None
    try:
        argv = [binary, "-c", config_path, "--", "/bin/sh", "-c", script, "sh", binary]
        pid, master = spawn(argv)
        data = read_until(master, b"", b"__START__:21:3")

        resize(master, 4)
        data = read_until(master, data, b"__SIZE__:2:3")
        before_set = len(data)
        os.write(master, b"SET\n")
        data = read_until(master, data, b"__SET__")
        assert b"hidden-value" not in data[before_set:], "hidden row was painted at height 4"

        resize(master, 24)
        data = read_until(master, data, b"__SIZE__:21:3")
        data = read_until(master, data, b"hidden-value")

        os.write(master, b"BAD\n")
        data = read_until(master, data, b"__BAD__:2")
        assert b"StatusBarSlot7=" not in data, "invalid update was written"
    finally:
        if pid is not None:
            stop(pid, master)
        os.unlink(config_path)

    exec_argv = [
        binary,
        "--lines", "3",
        "--exec", "printf 'exec-one\\nexec-two\\nexec-three\\n'",
        "--", "/bin/sh", "-c", "sleep 0.4",
    ]
    pid, master = spawn(exec_argv)
    try:
        data = read_until(master, b"", b"exec-three", 5)
        for value in (b"exec-one", b"exec-two", b"exec-three"):
            assert value in data
    finally:
        stop(pid, master)

    print("multirow PTY checks passed")


if __name__ == "__main__":
    main()
