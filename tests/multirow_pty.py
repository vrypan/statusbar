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
import urllib.parse


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


def check_init_invocation(binary):
    env = os.environ.copy()
    env["STATUSBAR_LINES"] = "2"
    with tempfile.TemporaryDirectory() as directory:
        stable = os.path.join(directory, "statusbar")
        os.symlink(binary, stable)

        absolute = subprocess.run(
            [stable, "init", "zsh"], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        )
        assert f"command '{stable}' set".encode() in absolute.stdout
        assert f"command '{binary}' set".encode() not in absolute.stdout

        path_env = env.copy()
        path_env["PATH"] = directory + os.pathsep + path_env.get("PATH", "")
        by_name = subprocess.run(
            ["statusbar", "init", "zsh"], env=path_env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        )
        assert b"command 'statusbar' set" in by_name.stdout

    print("shell init preserves upgrade-safe invocation paths")


def check_osc7_titles(binary):
    local = b"\x1b]7;file:///tmp/a%20project\x07"
    local_title = b"\x1b]2;/tmp/a project\x1b\\"
    child_title = b"\x1b]2;child-title\x1b\\"
    remote = b"\x1b]7;kitty-shell-cwd://server.example/srv/project\x1b\\"
    remote_title = b"\x1b]2;server.example:/srv/project\x1b\\"
    malformed = b"\x1b]7;file:///bad%zz\x07"
    oversized = b"\x1b]7;file:///" + (b"x" * 4097) + b"\x07"
    deep = b"\x1b]7;file:///one/two/three/four\x07"
    deep_title = b"\x1b]2;two/three/four\x1b\\"
    payload = local + child_title + remote + malformed + oversized + deep
    expected = local + local_title + child_title + remote + remote_title + malformed + oversized + deep + deep_title

    argv = [
        binary,
        "--config", "/dev/null",
        "--exec", "printf bar",
        "--", "/bin/sh", "-c", 'printf %s "$1"', "sh", payload.decode("ascii"),
    ]
    code, data = capture_pty(argv)
    assert code == 0, data
    assert expected in data, data[-6000:]
    print("OSC 7 forwarding and ordered terminal titles passed")


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
    assert invalid.returncode == 0
    assert b"__statusbar_report_cwd" in invalid.stdout

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

        # A slot that is absent from the current layout leaves Starship's
        # complete prompt in the terminal. The same installed hook can begin
        # using it after a later configuration reload adds the slot.
        one_row_env = zenv.copy()
        one_row_env["STATUSBAR_LINES"] = "1"
        script = (
            f'export STARSHIP_TEST_MODE=multi; eval "$({quoted_binary} init zsh)"; '
            "__statusbar_prompt"
        )
        code, data = capture_pty([zsh, "-f", "-c", script], one_row_env)
        assert code == 0, data
        assert b"SetUserVar=StatusBarSlot" not in data
        assert b"bar%%literal\r\nprompt" in data, data

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

        one_row_env = fenv.copy()
        one_row_env["STATUSBAR_LINES"] = "1"
        script = (
            f"set -gx STARSHIP_TEST_MODE multi; {quoted_binary} init fish | source; "
            "fish_prompt"
        )
        code, data = capture_pty([fish, "-N", "-c", script], one_row_env)
        assert code == 0, data
        assert b"SetUserVar=StatusBarSlot" not in data
        assert b"bar%literal\r\nprompt" in data, data

    print("fish integration passed")


def check_init_features(binary):
    env = os.environ.copy()
    env["STATUSBAR_LINES"] = "1"
    for shell in ("zsh", "fish"):
        for flags in (("--starship=false", "--report-cwd=false"),):
            result = subprocess.run([binary, "init", shell, *flags], env=env, capture_output=True)
            assert result.returncode == 0 and result.stdout == b"", result
        for flags in (("--starship=false", "--starship-slot=1"), ("--report-cwd=wrong",)):
            result = subprocess.run([binary, "init", shell, *flags], env=env, capture_output=True)
            assert result.returncode == 2 and result.stdout == b"", result
        result = subprocess.run([binary, "init", shell, "--report-cwd=false"], env=env, capture_output=True)
        assert result.returncode == 0 and b"__statusbar_report_cwd" not in result.stdout

        executable = shutil.which(shell)
        if executable is None:
            continue
        # Without Starship, default initialization still works in a one-row
        # session. Generation must not use the generator's own PATH to decide.
        generated = subprocess.run([binary, "init", shell], env=env, capture_output=True, check=True).stdout.decode()
        if shell == "zsh":
            script = 'PATH=/nonexistent; ' + generated + '\n__statusbar_report_cwd'
            args = [executable, "-f", "-c", script]
        else:
            script = 'set -gx PATH /nonexistent; ' + generated + '\nemit fish_prompt'
            args = [executable, "-N", "-c", script]
        code, data = capture_pty(args, env)
        assert code == 0 and b"\x1b]7;file://" in data, data
        assert b"does not exist" not in data and b"SetUserVar=" not in data, data
        with tempfile.TemporaryDirectory(prefix="statusbar-cwd-") as directory:
            target = os.path.join(directory, "space % café\ncontrol")
            os.mkdir(target)
            invocation = shlex.quote(binary) + " init " + shell + " --starship=false"
            if shell == "zsh":
                script = (
                    f'eval "$({invocation})"; eval "$({invocation})"; '
                    'cd -- "$1"; __statusbar_report_cwd; '
                    'print -r -- "hooks:${precmd_functions[*]}:${chpwd_functions[*]}"'
                )
                argv = [executable, "-f", "-c", script, "zsh", target]
            else:
                script = (
                    f"{invocation} | source; {invocation} | source; "
                    'cd -- "$argv[1]"; emit fish_prompt'
                )
                argv = [executable, "-N", "-c", script, target]
            code, data = capture_pty(argv, env)
            assert code == 0, data
            reports = re.findall(rb"\x1b\]7;file://[^/]*(/.*?)\x1b\\", data)
            assert len(reports) == 2, data
            for path in reports:
                assert urllib.parse.unquote_to_bytes(path.decode()) == target.encode(), (path, target)
                assert b"\n" not in path and b" " not in path and b"%25" in path, path
            assert b"SetUserVar=" not in data, data
            if shell == "zsh":
                assert b"hooks:__statusbar_report_cwd:__statusbar_report_cwd" in data, data
    print("independent init features and repeatable encoded CWD hooks passed")


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
            cfg.write("[highlight]\npulses = 1\n")
        pid, master = spawn([binary, "-c", config_path, "--", "/bin/sh", "-c", "sleep 10"])
        try:
            suffix = b"\x1b[0m\x1b8\x1b[?7h"
            initial = b""
            if colors:
                initial = read_until(master, initial, b"\x1b[6n")
                assert b"\x1b]10;?\x1b\\" in initial and b"\x1b]11;?\x1b\\" in initial
                os.write(master, b"\x1b]10;rgb:e6/d2/aa\x1b\\"
                                 b"\x1b]11;rgb:16/14/12\x1b\\"
                                 b"\x1b[1;1R")
            initial = read_until(master, initial, b"PREFIX one BETWEEN other SUFFIX")
            start = initial.index(b"PREFIX one BETWEEN other SUFFIX")
            initial = initial[:start] + read_until(master, initial[start:], suffix)
            assert b"\x1b[0;1m" not in initial and b"48;2;" not in initial, initial
            # Atomic replacement avoids an intermediate empty command result.
            next_path = os.path.join(folder, "next")
            with open(next_path, "w") as value:
                value.write("two-long\n")
            os.replace(next_path, value_path)
            marker = b"\x1b[0;38;2;" if colors else b"\x1b[0;1m"
            highlighted = read_until(master, b"", marker)
            highlighted = read_until(master, highlighted, b"two-long")
            highlighted = read_until(master, highlighted, suffix)
            highlighted_style = painted_styles(highlighted)[len("PREFIX ")][1]
            if colors:
                assert b"38;2;" in highlighted_style and b"48;2;" in highlighted_style
            else:
                assert highlighted_style == b"0;1"
            for label in ("PREFIX ", " BETWEEN ", "other", " SUFFIX", ".", "RIGHT"):
                assert_region_style(highlighted, label, b"0")
            resize(master, 24, 90)
            restored = read_until(master, b"", b"PREFIX two-long BETWEEN other SUFFIX")
            restored = read_until(master, restored, suffix)
            assert_region_style(restored, "two-long", b"0")
            assert_region_style(restored, "other", b"0")
            with open(next_path, "w") as value:
                value.write("second-new\n")
            os.replace(next_path, second_path)
            second = read_until(master, b"", marker)
            second = read_until(master, second, b"second-new")
            second = read_until(master, second, suffix)
            second_style = painted_styles(second)[len("PREFIX two-long BETWEEN ")][1]
            if colors:
                assert b"38;2;" in second_style and b"48;2;" in second_style
            else:
                assert second_style == b"0;1"
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
    print("independent adaptive RGB regions passed" if colors else "independent fallback regions passed")


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
            cfg.write(f"""[line.1]
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


def check_logging(binary):
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "session.log")
        for command in (["run", "--log", path], ["--log", path]):
            code, data = capture_pty([
                binary, *command, "-e", "printf LOG_BAR", "--",
                "/bin/sh", "-c", "printf LOG_CHILD; exit 7",
            ])
            assert code == 7, (code, data)
            assert b"LOG_CHILD" in data
            assert b"session started:" not in data
        with open(path) as log:
            text = log.read()
        assert len(re.findall(r"^\d+ statusbar: session started:", text, re.M)) == 2, text
        assert text.count("session ended: exit=7") == 2, text
        assert "LOG_CHILD" not in text and "LOG_BAR" not in text, text
        assert os.stat(path).st_mode & 0o777 == 0o600
        fifo = os.path.join(folder, "fifo")
        os.mkfifo(fifo)
        for invalid in [folder, os.path.join(folder, "missing", "log"), fifo, "/dev/null"]:
            result = subprocess.run([
                binary, "run", "--log", invalid, "--", "/bin/sh", "-c", "printf SHOULD_NOT_RUN",
            ], capture_output=True, timeout=5)
            assert result.returncode != 0
            assert b"cannot open log file" in result.stderr, result.stderr
            assert not result.stdout and b"\x1b[" not in result.stderr
    print("logging append, permissions, exit status, and startup failures passed")


def check_osc_config(binary):
    initial = "[line.1]\nleft = ORIGINAL\n"
    replacement = "[line.1]\nleft = REPLACED_ONE\n[line.2]\nleft = REPLACED_TWO\n"
    direct = '[line.1]\nleft = "DIRECT; Καλημέρα"\n'
    with tempfile.TemporaryDirectory() as folder:
        initial_path = os.path.join(folder, "initial")
        replacement_path = os.path.join(folder, "replacement")
        log_path = os.path.join(folder, "session.log")
        nested_token_path = os.path.join(folder, "nested-token")
        rejected_command_path = os.path.join(folder, "rejected-command-ran")
        with open(initial_path, "w") as config_file:
            config_file.write(initial)
        with open(replacement_path, "w") as config_file:
            config_file.write(replacement)
        for args, expected in [
            (["--path", "--default"], b"built-in\n"),
            (["--path", "--config", initial_path], os.fsencode(initial_path) + b"\n"),
        ]:
            result = subprocess.run([binary, "config", *args], capture_output=True)
            assert result.returncode == 0 and result.stdout == expected, result
        for args in [
            ["--default", "--config", initial_path],
            ["--load", replacement_path, "--default"],
            ["--load", replacement_path, "--config", initial_path],
        ]:
            result = subprocess.run([binary, "config", *args], capture_output=True)
            assert result.returncode == 2 and not result.stdout, result
        no_session = subprocess.run(
            [binary, "config", "--load", replacement_path],
            capture_output=True, check=False,
        )
        assert no_session.returncode == 2 and not no_session.stdout
        assert b"not inside a compatible statusbar session" in no_session.stderr
        incompatible = subprocess.run(
            [binary, "config", "--load", replacement_path, "--path"],
            capture_output=True, check=False,
        )
        assert incompatible.returncode == 2 and not incompatible.stdout
        oversized_path = os.path.join(folder, "oversized")
        with open(oversized_path, "w") as config_file:
            config_file.write("#" + "x" * 24522 + "\n")
        oversized_env = os.environ.copy()
        oversized_env["STATUSBAR_SESSION_ID"] = "0" * 32
        oversized = subprocess.run(
            [binary, "config", "--load", oversized_path], env=oversized_env,
            capture_output=True, check=False,
        )
        assert oversized.returncode != 0 and not oversized.stdout
        child = r'''
import base64, os, subprocess, sys
binary, replacement, direct, nested_token_path, rejected_command_path = sys.argv[1:]
def frame(config, token=None):
    token = token or os.environ["STATUSBAR_SESSION_ID"]
    envelope = b"1;" + token.encode() + b";" + config.encode()
    return b"\x1b]3110;STATUSBAR;CONFIG;" + base64.b64encode(envelope) + b"\x1b\\"
def emit(config, token=None):
    os.write(1, frame(config, token))
print("OSC_CONFIG_READY", flush=True)
for command in sys.stdin:
    command = command.strip()
    if command == "BAD":
        rejected = f"[line.1]\nleft = #(bad)\n[command.bad]\nrun = touch {rejected_command_path}\n"
        emit(rejected, "0" * 32)
        print("__BAD__", flush=True)
    elif command == "LOAD":
        result = subprocess.run([binary, "config", "--load", replacement])
        print(f"__LOAD__:{result.returncode}", flush=True)
    elif command == "DIRECT":
        emit(direct)
        print("__DIRECT__", flush=True)
    elif command == "ORDER":
        first = "[line.1]\nleft = ORDER_ONE\n[line.2]\nleft = ORDER_TWO\n"
        final = "[line.1]\nleft = FINAL_ONE\n[line.2]\nleft = FINAL_TWO\n"
        slot = b"\x1b]1337;SetUserVar=StatusBarSlot4=S0VFUA==\x1b\\"
        os.write(1, frame(first) + slot + frame(final))
        print("__ORDER__", flush=True)
    elif command == "SAVED":
        os.write(1, b"\x1b7")
        emit('[line.1]\nleft = SHOULD_NOT_APPLY\n')
        os.write(1, b"\x1b8")
        print("__SAVED__", flush=True)
    elif command == "NESTED":
        code = 'import os,sys; open(sys.argv[1], "w").write(os.environ["STATUSBAR_SESSION_ID"])'
        result = subprocess.run([binary, "-e", "printf NESTED_BAR", "--", sys.executable, "-c", code, nested_token_path])
        nested = open(nested_token_path).read()
        print(f"__NESTED__:{result.returncode}:{nested != os.environ['STATUSBAR_SESSION_ID']}", flush=True)
    elif command == "EXIT":
        raise SystemExit(0)
'''
        pid, master = spawn([
            binary, "--log", log_path, "-c", initial_path, "--",
            sys.executable, "-u", "-c", child, binary, replacement_path, direct,
            nested_token_path, rejected_command_path,
        ], rows=12)
        data = b""
        try:
            data = read_until(master, data, b"OSC_CONFIG_READY", timeout=5)
            data = read_until(master, data, b"ORIGINAL", timeout=5)
            os.write(master, b"BAD\n")
            data = read_until(master, data, b"__BAD__", timeout=3)
            assert not os.path.exists(rejected_command_path)
            os.write(master, b"LOAD\n")
            data = read_until(master, data, b"__LOAD__:0", timeout=5)
            data = read_until(master, data, b"REPLACED_TWO", timeout=5)
            assert b"\x1b[1;10r" in data, data[-1000:]
            os.write(master, b"DIRECT\n")
            data = read_until(master, data, "DIRECT; Καλημέρα".encode(), timeout=5)
            data = read_until(master, data, b"__DIRECT__", timeout=3)
            os.write(master, b"ORDER\n")
            data = read_until(master, data, b"FINAL_TWO", timeout=5)
            data = read_until(master, data, b"KEEP", timeout=5)
            data = read_until(master, data, b"__ORDER__", timeout=3)
            os.write(master, b"NESTED\n")
            data = read_until(master, data, b"__NESTED__:0:True", timeout=5)
            os.write(master, b"SAVED\n")
            data = read_until(master, data, b"__SAVED__", timeout=3)
            assert b"SHOULD_NOT_APPLY" not in data
            assert b"3110;STATUSBAR" not in data
            deadline = time.monotonic() + 3
            while True:
                with open(log_path) as log_file:
                    logged = log_file.read()
                if "OSC config rejected: child cursor is saved" in logged:
                    break
                assert time.monotonic() < deadline, logged
                time.sleep(0.05)
            assert "OSC config applied: rows=2" in logged
            assert "OSC config applied: rows=1" in logged
            assert "AuthenticationFailed" in logged
            assert "REPLACED_ONE" not in logged and "Καλημέρα" not in logged
            os.write(master, b"EXIT\n")
        finally:
            stop(pid, master)
    print("authenticated OSC config replacement and rejection passed")


def check_theme_growth(binary):
    # The new region must precede text in the very same child write.
    child = r'''
import os, base64, time
text = ''.join('[line.%d]\nleft = ROW%d\n' % (n, n) for n in range(1, 6))
envelope = b'1;' + os.environ['STATUSBAR_SESSION_ID'].encode() + b';' + text.encode()
frame = b'\x1b]3110;STATUSBAR;CONFIG;' + base64.b64encode(envelope) + b'\x1b\\'
os.write(1, frame + b'\nAFTER_CONFIG\n')
time.sleep(.3)
'''
    pid, master = spawn([binary, "-n", "2", "-e", "printf BEFORE_BAR", "--", sys.executable, "-c", child], rows=24)
    try:
        data = read_until(master, b"", b"AFTER_CONFIG", timeout=5)
        assert data.index(b"\x1b7\x1b[1;19r\x1b8") < data.index(b"AFTER_CONFIG"), data
    finally:
        stop(pid, master)
    pastel = os.path.abspath("samples/themes/pastel-powerline.config")
    multi = os.path.abspath("samples/themes/multi-line.config")
    script = r'''
printf THEME_GROWTH_READY
IFS= read -r command
"$1" config --load "$2"
printf __THEME_LOADED__
IFS= read -r command
'''
    pid, master = spawn([
        binary, "-c", pastel, "--", "/bin/sh", "-c", script, "sh", binary, multi,
    ], rows=24)
    data = b""
    try:
        data = read_until(master, data, b"THEME_GROWTH_READY", timeout=5)
        os.write(master, b"LOAD\n")
        data = read_until(master, data, b"__THEME_LOADED__", timeout=5)
        data = read_until(master, data, b"\x1b[1;19r", timeout=5)
        growth = b"\x1b7\x1b[22;1H\n\n\n\x1b8\x1b[19d"
        assert growth in data, data[-2000:]
        assert b"\x1b[20;1H" in data and b"\x1b[24;1H" in data, data[-2000:]
        os.write(master, b"EXIT\n")
    finally:
        stop(pid, master)
    print("two-row to five-row theme growth preserves terminal geometry")


def check_config_dialog(binary):
    config = """\
[line.1]
left = RELOADED_ONE
[line.2]
left = RELOADED_TWO
[line.3]
left = RELOADED_THREE
"""
    with tempfile.NamedTemporaryFile("w", delete=False) as cfg:
        cfg.write(config)
        config_path = cfg.name
    log_path = config_path + ".log"
    pid = master = None
    try:
        script = r'''
printf RELOAD_READY
while IFS= read -r command; do
  case "$command" in
    SET) "$1" set 6 LIVE_SLOT; printf '__SET__\n' ;;
    EXIT) exit 0 ;;
  esac
done
'''
        pid, master = spawn([
            binary, "--log", log_path, "-e", "printf RELOAD_READY", "--",
            "/bin/sh", "-c", script, "sh", binary,
        ], rows=12)
        data = read_until(master, b"", b"RELOAD_READY", timeout=5)
        os.write(master, b"\x18\x12")
        data = read_until(master, data, b"Enter config path:", timeout=3)
        os.write(master, b"\x15" + os.fsencode(config_path + ".missing") + b"\r")
        deadline = time.monotonic() + 3
        while True:
            with open(log_path) as log:
                if "config replacement failed: file inspection" in log.read():
                    break
            assert time.monotonic() < deadline, "config rejection was not logged"
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                data += os.read(master, 65536)
        with open(log_path) as log:
            assert "config replacement failed: file inspection" in log.read()
        os.write(master, b"\x15" + os.fsencode(config_path) + b"\r")
        data = read_until(master, data, b"RELOADED_THREE", timeout=5)
        assert b"\x1b[1;9r" in data, data[-1000:]
        os.write(master, b"SET\n")
        data = read_until(master, data, b"__SET__", timeout=3)
        data = read_until(master, data, b"LIVE_SLOT", timeout=3)
        with open(config_path, "w", encoding="utf-8") as replacement:
            replacement.write("[line.1]\nleft = SHRUNK\n")
        before_shrink = len(data)
        os.write(master, b"\x18\x12")
        data += read_until(master, b"", b"Enter config path:", timeout=3)
        os.write(master, b"\r")
        data += read_until(master, b"", b"SHRUNK", timeout=5)
        assert b"\x1b[1;11r" in data[before_shrink:], data[-1000:]
        with open(log_path) as log:
            logged = log.read()
        assert "config replaced: rows=3" in logged and "config replaced: rows=1" in logged, logged
        assert "RELOADED_THREE" not in logged
        os.write(master, b"EXIT\n")
    finally:
        if pid is not None:
            stop(pid, master)
        os.unlink(config_path)
        os.unlink(log_path)
    print("interactive config replacement and row growth passed")


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

    check_init_invocation(binary)
    check_osc7_titles(binary)
    check_zsh(binary)
    check_fish(binary)
    check_init_features(binary)
    check_tracking(binary)
    check_tracking(binary, colors=True)
    check_geometry_results_do_not_highlight(binary)
    check_adaptive_palette(binary)
    check_logging(binary)
    check_osc_config(binary)
    check_theme_growth(binary)
    check_config_dialog(binary)
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
