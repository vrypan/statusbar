#!/usr/bin/env python3
"""Theme discovery, terminal restoration, and live config replacement."""
import base64
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import termios

from multirow_pty import read_until, resize, spawn, stop

TOKEN = "0123456789abcdef0123456789abcdef"
PREFIX = b"\x1b]3110;STATUSBAR;CONFIG;"


def expect(fd, data, marker):
    data = read_until(fd, data, marker)
    assert marker in data, data[-2000:]
    return data


def pick(binary, directory, keys, *, resize_to=None, apply_marker=PREFIX, again=None):
    script = '''
before=$(stty -g)
"$1" "$2"
code=$?
after=$(stty -g)
printf '__TERMIOS_%s_TO_%s__' "$before" "$after"
printf '__RESULT_%s____PICK_FINISHED__' "$code"
IFS= read -r done
'''
    env = dict(os.environ, STATUSBAR_SESSION_ID=TOKEN)
    pid, fd = spawn(["/bin/sh", "-c", script, "sh", binary, str(directory)], env=env)
    try:
        data = expect(fd, b"", b"Enter apply")
        if resize_to:
            resize(fd, *resize_to)
            # A resize forces a full repaint. Wait before sending navigation.
            data += expect(fd, b"", b"\x1b[2J")
        os.write(fd, keys)
        if b"\r" in keys:
            data = expect(fd, data, apply_marker)
            assert b"__PICK_FINISHED__" not in data, data
            if again:
                os.write(fd, again)
                data += expect(fd, b"", PREFIX)
            os.write(fd, b"q")
        data = expect(fd, data, b"__PICK_FINISHED__")
        before, after = re.search(rb"__TERMIOS_(.*?)_TO_(.*?)__", data).groups()
        # macOS sets PENDIN when returning to canonical mode. It is kernel
        # bookkeeping; compare every other flag and all control characters.
        def normalize(value):
            return re.sub(rb"lflag=([0-9a-f]+)", lambda m:
                          b"lflag=" + format(int(m[1], 16) & ~getattr(termios, "PENDIN", 0), "x").encode(), value)
        assert normalize(before) == normalize(after), (before, after)
        return data
    finally:
        stop(pid, fd)


def check_picker(binary, root):
    themes = root / "themes with spaces"
    themes.mkdir()
    a = b"[line.1]\nleft = FIRST\n"
    z = b"[line.1]\nleft = LAST\n"
    (themes / "z-last.config").write_bytes(z)
    (themes / "a first.config").write_bytes(a)
    (themes / "b-link.config").symlink_to("a first.config")
    (themes / "broken.config").symlink_to("missing")
    (themes / "ignored.config").mkdir()
    (themes / "README.md").write_text("not a theme")
    os.mkfifo(themes / "pipe.config")
    data = pick(binary, themes, b"\x1b[B\x1b[B\r")
    assert data.index(b"a first.config") < data.index(b"b-link.config") < data.index(b"z-last.config")
    for hidden in (b"README.md", b"ignored.config", b"pipe.config", b"broken.config"):
        assert hidden not in data, data
    frame = re.search(re.escape(PREFIX) + rb"([^\x1b]+)\x1b\\", data)
    assert frame, data
    assert base64.b64decode(frame[1]) == b"1;" + TOKEN.encode() + b";" + z
    assert frame.start() < data.index(b"\x1b[?1049l"), data
    assert b"__RESULT_0__" in data, data

    data = pick(binary, themes, b"\x1b[F\r", again=b"\x1b[H\r")
    frames = re.findall(re.escape(PREFIX) + rb"([^\x1b]+)\x1b\\", data)
    assert len(frames) == 2 and base64.b64decode(frames[0]).endswith(z) and base64.b64decode(frames[1]).endswith(a), data

    for keys in (b"q", b"\x1b", b"\x03"):
        data = pick(binary, themes, keys)
        assert PREFIX not in data and b"__RESULT_0__" in data, data

    # Page/End/Home navigation after a resize to a one-row terminal.
    data = pick(binary, themes, b"\x1b[F\x1b[Hj\r", resize_to=(1, 12))
    frame = re.search(re.escape(PREFIX) + rb"([^\x1b]+)\x1b\\", data)
    assert frame and base64.b64decode(frame[1]).endswith(a), data

    invalid = root / "invalid"
    invalid.mkdir()
    for contents, diagnostic in ((b"[unknown]\n", b"unknown"), (b"", b"empty config"),
                                (b"#" * 30000, b"limit")):
        (invalid / "bad.config").write_bytes(contents)
        data = pick(binary, invalid, b"\r", apply_marker=diagnostic)
        assert PREFIX not in data and diagnostic in data, data
        assert b"__RESULT_0__" in data, data
    print("picker: discovery, selection, cancellation, resize, validation, restoration")


def check_live(picker, statusbar, root):
    themes = root / "live"
    themes.mkdir()
    old = "[line.1]\nleft = OLD_THEME\n"
    new = "".join(f"[line.{i}]\nleft = NEW_ROW_{i}\n" for i in range(1, 6))
    initial = root / "initial.config"
    initial.write_text(old)
    selected = themes / "new.config"
    script = '''
"$1" "$2"
printf '__PICKER_DONE__'
IFS= read -r go
"$3" config --print current
printf '__SNAPSHOT_DONE__'
IFS= read -r done
'''
    for contents, keys, expected in ((new, b"\r", new), (new, b"q", old),
                                     ("[unknown]\n", b"\r", old)):
        selected.write_text(contents)
        env = os.environ.copy()
        env.pop("STATUSBAR_SESSION_ID", None)
        env.pop("STATUSBAR_STATE", None)
        pid, fd = spawn([statusbar, "-c", str(initial), "--", "/bin/sh", "-c", script,
                         "sh", picker, str(themes), statusbar], env=env)
        try:
            data = expect(fd, b"", b"Enter apply")
            os.write(fd, keys)
            if keys == b"\r":
                data = expect(fd, data, b"Applied:" if expected == new else b"unknown")
                assert b"__PICKER_DONE__" not in data, data
                os.write(fd, b"q")
            data = expect(fd, data, b"__PICKER_DONE__")
            os.write(fd, b"SNAPSHOT\n")
            snapshot = expect(fd, b"", b"__SNAPSHOT_DONE__")
            assert expected.replace("\n", "\r\n").encode() in snapshot, snapshot
            if expected == new:
                assert b"\x1b[1;19r" in data + snapshot, data + snapshot
        finally:
            stop(pid, fd)
    print("picker: live activation grows rows; cancel and invalid config preserve session")


def main():
    picker, statusbar = map(os.path.abspath, sys.argv[1:])
    env = os.environ.copy()
    env.pop("STATUSBAR_SESSION_ID", None)
    assert subprocess.run([picker, "--help"], capture_output=True, env=env).returncode == 0
    result = subprocess.run([picker, "."], capture_output=True, env=env)
    assert result.returncode == 2 and b"inside a statusbar session" in result.stderr
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        result = subprocess.run([picker, directory], capture_output=True,
                                env=dict(env, STATUSBAR_SESSION_ID=TOKEN))
        assert result.returncode == 1 and b"no .config files" in result.stderr
        check_picker(picker, root)
        check_live(picker, statusbar, root)


if __name__ == "__main__":
    main()
