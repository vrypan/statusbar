#!/usr/bin/env python3
"""Deterministic PTY checks for configured rows, resizing, and slot updates."""

import base64
import fcntl
import os
import pty
import re
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


def painted_styles(data):
    """Read the last bar row's SGR state per character, independent of runs."""
    row = data[data.rindex(b"\x1b[24;1H") + len(b"\x1b[24;1H"):]
    row = row.split(b"\x1b8", 1)[0]
    parts = re.split(rb"(\x1b\[[0-?]*[ -/]*[@-~])", row)
    style = b"0"
    result = []
    for part in parts:
        if part.startswith(b"\x1b["):
            if part.endswith(b"m"):
                style = part[2:-1]
        elif not part.startswith(b"\x1b"):
            result.extend((char, style) for char in part.decode("utf-8"))
    return result


def assert_region_style(data, value, expected):
    cells = painted_styles(data)
    text = "".join(char for char, _ in cells)
    start = text.index(value)
    assert all(style == expected for _, style in cells[start:start + len(value)]), (value, cells)


def check_tracking(binary, colors=False):
    with tempfile.TemporaryDirectory(prefix="statusbar-tracking-") as folder:
        value_path = os.path.join(folder, "value")
        second_path = os.path.join(folder, "second")
        config_path = os.path.join(folder, "config")
        with open(value_path, "w") as value:
            value.write("one\n")
        with open(second_path, "w") as value:
            value.write("other\n")
        with open(config_path, "w") as cfg:
            cfg.write(f"""[line.1]
left = PREFIX #[track]#(value)#[notrack] BETWEEN #[track]#(second)#[notrack] SUFFIX
right = RIGHT
rule = .
[command.value]
run = cat {shlex.quote(value_path)}
interval = 0.1
[command.second]
run = cat {shlex.quote(second_path)}
interval = 0.1
""")
            if colors:
                cfg.write("[highlight]\nbackgrounds = #9e7b20, #70591d, #44391c\nforegrounds = #fff4cc, #eedaae, #dcc290\nstep = 0.15\n")
            else:
                cfg.write("[highlight]\neffect = bold\n")
        pid, master = spawn([binary, "-c", config_path, "--", "/bin/sh", "-c", "sleep 10"])
        try:
            suffix = b"\x1b[0m\x1b8\x1b[?7h"
            initial = read_until(master, b"", b"PREFIX one BETWEEN other SUFFIX")
            start = initial.index(b"PREFIX one BETWEEN other SUFFIX")
            initial = initial[:start] + read_until(master, initial[start:], suffix)
            assert b"\x1b[0;1m" not in initial and b"48;2;" not in initial, initial
            # Atomic replacement avoids an intermediate empty command result.
            next_path = os.path.join(folder, "next")
            with open(next_path, "w") as value:
                value.write("two-long\n")
            os.replace(next_path, value_path)
            steps = ([b"\x1b[0;38;2;255;244;204;48;2;158;123;32m",
                      b"\x1b[0;38;2;238;218;174;48;2;112;89;29m",
                      b"\x1b[0;38;2;220;194;144;48;2;68;57;28m"]
                     if colors else [b"\x1b[0;1m"])
            highlighted = read_until(master, b"", steps[0] + b"two-long")
            highlighted = read_until(master, highlighted, suffix)
            assert_region_style(highlighted, "two-long", steps[0][2:-1])
            for label in ("PREFIX ", " BETWEEN ", "other", " SUFFIX", ".", "RIGHT"):
                assert_region_style(highlighted, label, b"0")
            resize(master, 24, 90)
            for step in steps[1:]:
                frame = read_until(master, b"", step + b"two-long")
                frame = read_until(master, frame, suffix)
                assert_region_style(frame, "two-long", step[2:-1])
                assert_region_style(frame, "other", b"0")
            restored = read_until(master, b"", b"PREFIX two-long BETWEEN other SUFFIX")
            restored = read_until(master, restored, suffix)
            assert_region_style(restored, "two-long", b"0")
            assert_region_style(restored, "other", b"0")
            with open(next_path, "w") as value:
                value.write("second-new\n")
            os.replace(next_path, second_path)
            second = read_until(master, b"", steps[0] + b"second-new")
            second = read_until(master, second, suffix)
            assert_region_style(second, "second-new", steps[0][2:-1])
            for label in ("PREFIX ", "two-long", " BETWEEN ", " SUFFIX", ".", "RIGHT"):
                assert_region_style(second, label, b"0")
            restored = read_until(master, b"", b"PREFIX two-long BETWEEN second-new SUFFIX")
            restored = read_until(master, restored, suffix)
            # Repeated identical command results should not restart the timer
            # or cause another repaint after the restore.
            ready, _, _ = select.select([master], [], [], 0.4)
            assert not ready, "identical tracked results repainted the bar"
        finally:
            stop(pid, master)
    print("independent region color sequence passed" if colors else "independent region highlight passed")


def check_geometry_results_do_not_highlight(binary):
    with tempfile.TemporaryDirectory(prefix="statusbar-geometry-") as folder:
        value_path = os.path.join(folder, "value")
        config_path = os.path.join(folder, "config")
        with open(value_path, "w") as value:
            value.write("one\n")
        with open(config_path, "w") as cfg:
            cfg.write(f"""[line.1]
left = VALUE #[track]#(value)#[notrack]
[command.value]
run = printf 'cols:%s:' \"$STATUSBAR_COLUMNS\"; cat {shlex.quote(value_path)}
interval = 0.2
""")
        pid, master = spawn([binary, "-c", config_path, "--", "/bin/sh", "-c", "sleep 10"])
        try:
            suffix = b"\x1b[0m\x1b8\x1b[?7h"
            initial = read_until(master, b"", b"cols:80:one")
            start = initial.index(b"cols:80:one")
            initial = initial[:start] + read_until(master, initial[start:], suffix)
            assert b"\x1b[0;1m" not in initial, initial

            resize(master, 24, 60)
            resized = read_until(master, b"", b"cols:60:one")
            start = resized.index(b"cols:60:one")
            resized = resized[:start] + read_until(master, resized[start:], suffix)
            assert b"\x1b[0;1m" not in resized, resized

            next_path = os.path.join(folder, "next")
            with open(next_path, "w") as value:
                value.write("two\n")
            os.replace(next_path, value_path)
            highlighted = read_until(master, b"", b"\x1b[0;1mcols:60:two")
            highlighted = read_until(master, highlighted, suffix)
            assert b"cols:60:two" in highlighted, highlighted
        finally:
            stop(pid, master)
    print("geometry command results establish a silent baseline")


def check_adaptive_palette(binary):
    """Emulate terminal queries, including a subsequent child-owned query."""
    with tempfile.TemporaryDirectory(prefix="statusbar-palette-") as folder:
        value_path = os.path.join(folder, "value")
        config_path = os.path.join(folder, "config")
        with open(value_path, "w") as value:
            value.write("one\n")
        with open(config_path, "w") as cfg:
            cfg.write(f"""[highlight]
effect = relative
[line.1]
left = LABEL #[track]#[fg=red,bg=blue]#(value) #[default]D#[notrack] END
[command.value]
run = cat {shlex.quote(value_path)}
interval = 0.1
""")
        child = """import os, tty, time, termios
tty.setraw(0, when=termios.TCSANOW)
key = b''
while len(key) < 7: key += os.read(0, 7-len(key))
os.write(1, b'__KEY__:' + key.hex().encode() + b'\\n')
os.write(1, b'\\x1b]4;200;?\\x1b\\\\')
reply = b''
while not reply.endswith(b'\\x1b\\\\'): reply += os.read(0, 128)
os.write(1, b'__REPLY__:' + reply.hex().encode() + b'\\n')
time.sleep(10)
"""
        pid, master = spawn([binary, "-c", config_path, "--", sys.executable, "-c", child])
        try:
            queries = read_until(master, b"", b"\x1b[6n")
            assert b"\x1b]10;?\x1b\\" in queries and b"\x1b]11;?\x1b\\" in queries, queries
            assert b"\x1b]4;255;?\x1b\\" in queries, queries
            # Exercise BEL, ST, 8-bit and 16-bit component precision, and a
            # reply fragmented immediately after ESC.
            os.write(master, b"queued\n\x1b")
            os.write(master, b"]10;rgb:e6/d2/aa\x07\x1b]11;rgb:1616/1414/1212\x1b\\"
                             b"\x1b]4;1;rgb:bc/46/50\x07\x1b]4;4;rgb:1e/28/41\x1b\\"
                             b"\x1b[1;1R")
            data = read_until(master, b"", b"__KEY__:7175657565640a")
            data = read_until(master, data, b"\x1b]4;200;?\x1b\\")
            own_reply = b"\x1b]4;200;rgb:ff/00/ff\x1b\\"
            os.write(master, own_reply)
            data = read_until(master, data, b"__REPLY__:" + own_reply.hex().encode())
            data = read_until(master, data, b"\x1b[0;38;5;1;48;5;4mone")
            data = read_until(master, data, b"\x1b[0m\x1b8\x1b[?7h")
            next_path = os.path.join(folder, "next")
            with open(next_path, "w") as value:
                value.write("two\n")
            os.replace(next_path, value_path)
            changed = read_until(master, b"", b"two")
            changed = read_until(master, changed, b"\x1b[0m\x1b8\x1b[?7h")
            # The pulse starts at the exact base style. Inspect the first
            # subsequent RGB frame, not the content update at time zero.
            assert_region_style(changed, "two", b"0;38;5;1;48;5;4")
            changed = read_until(master, b"", b"\x1b[0;38;2;")
            changed = read_until(master, changed, b"\x1b[0m\x1b8\x1b[?7h")
            cells = painted_styles(changed)
            text = "".join(char for char, _ in cells)
            value_style = cells[text.index("two")][1]
            default_style = cells[text.index("D", text.index("two"))][1]
            for style in (value_style, default_style):
                assert b"38;2;" in style and b"48;2;" in style, cells
            assert value_style != default_style, cells
            assert_region_style(changed, "LABEL ", b"0")
            assert_region_style(changed, " END", b"0")
            animated_at = time.monotonic()
            restored = read_until(master, b"", b"\x1b[0;38;5;1;48;5;4mtwo", 4)
            # No original palette tokens between the two peaks: restoration
            # happens after the whole 2.4-second animation, not at 1.2 seconds.
            assert time.monotonic() - animated_at > 1.8, "restored between pulses"
            restored = read_until(master, restored, b"\x1b[0m\x1b8\x1b[?7h")
            assert_region_style(restored, "two", b"0;38;5;1;48;5;4")
            assert_region_style(restored, "D END", b"0")
            colors = set(re.findall(rb"\x1b\[(0;38;2;[0-9;]+)m", changed + restored))
            assert len(colors) >= 8, colors
            ready, _, _ = select.select([master], [], [], 0.3)
            assert not ready, "adaptive effect failed to settle"
        finally:
            stop(pid, master)
    print("adaptive palette pulse, input preservation, and child query ownership passed")


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
    check_tracking(binary)
    check_tracking(binary, colors=True)
    check_geometry_results_do_not_highlight(binary)
    check_adaptive_palette(binary)
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
while :; do
  IFS= read -r command || continue
  case "$command" in
    SET) "$statusbar_bin" set 6 hidden-value; printf '__SET__\n' ;;
    ROW) "$statusbar_bin" set 3 changed-row-two ;;
    CLEAR) printf '\033[2J__CLEAR__\n' ;;
    ALT) printf '\033[?1049h__ALT__\n' ;;
    NORMAL) printf '\033[?1049l__NORMAL__\n' ;;
    BYTES) printf '\033[32m__FORWARDED__\033[0m\n' ;;
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
        data = read_until(master, data, b"configured-six")
        suffix = b"\x1b[0m\x1b8\x1b[?7h"
        # Finish the content-bearing startup paint, not an earlier blank paint.
        start = data.index(b"configured-six")
        data = data[:start] + read_until(master, data[start:], suffix)

        os.write(master, b"ROW\n")
        batch = read_until(master, b"", b"changed-row-two")
        batch = read_until(master, batch, suffix)
        assert b"\x1b[23;1H" in batch, batch
        assert b"\x1b[22;1H" not in batch and b"\x1b[24;1H" not in batch, batch

        for command, marker in ((b"CLEAR\n", b"__CLEAR__"),
                                (b"ALT\n", b"__ALT__"),
                                (b"NORMAL\n", b"__NORMAL__")):
            os.write(master, command)
            batch = read_until(master, b"", marker)
            batch = read_until(master, batch, suffix)
            for row in (22, 23, 24):
                assert f"\x1b[{row};1H".encode() in batch, batch

        os.write(master, b"BYTES\n")
        forwarded = b"\x1b[32m__FORWARDED__\x1b[0m"
        assert forwarded in read_until(master, b"", forwarded)

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

        # A huge width exceeds the bounded renderer budget during resize.
        # It must terminate, restore terminal modes, and print a diagnostic.
        before = termios.tcgetattr(master)
        resize(master, 24, 65535)
        failed = read_until(master, b"", b"statusbar: cannot start the terminal proxy", 20)
        assert b"\x1b[r" in failed, failed
        after = termios.tcgetattr(master)
        assert after[3] & termios.ICANON and after[3] & termios.ECHO, (before, after)
    finally:
        if pid is not None:
            stop(pid, master)
        os.unlink(config_path)

    exec_argv = [
        binary,
        "--config", "/dev/null",
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
