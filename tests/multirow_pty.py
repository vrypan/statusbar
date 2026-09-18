#!/usr/bin/env python3
"""Deterministic PTY checks for configured rows, resizing, and slot updates."""

import base64
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import tempfile
import time


def resize(fd, rows, cols=80):
    fcntl.ioctl(fd, 0x80087467, struct.pack("HHHH", rows, cols, 0, 0))


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


def spawn(argv, rows=24):
    ready_r, ready_w = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.close(ready_w)
        os.read(ready_r, 1)
        os.close(ready_r)
        os.execv(argv[0], argv)
    os.close(ready_r)
    resize(master, rows)
    os.write(ready_w, b"x")
    os.close(ready_w)
    return pid, master


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
