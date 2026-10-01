#!/usr/bin/env python3
"""Deterministic PTY checks for named lines, templates, resizing, and line control."""

import base64
import fcntl
import json
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
import unicodedata
import urllib.parse


def resize(fd, rows, cols=80):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    bar_screen(fd).cols = cols


PAINT_START = b"\x1b7\x1b[?7l"
PAINT_TOKEN = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[()][0-~]|\x1b.|[^\x1b]+", re.S)
LINK_CLOSE = b"\x1b]8;;\x1b\\"
CONTINUATION = None


class BarScreen:
    """Rebuilds each bar row the renderer paints, so checks can read every
    paint as the whole row it leaves on screen.

    An ordinary update rewrites only the columns that changed. Reads from
    the PTY pass through `feed`, which replaces each such row with the row
    as it now appears, written from its first column the way a full
    repaint writes it. Rows painted after an erase are complete already
    and pass through unchanged.
    """

    def __init__(self):
        self.cols = 80
        self.rows = {}
        self.pending = b""

    def row(self, number):
        return self.rows.setdefault(number, [(" ", b"0", b"")] * self.cols)

    def feed(self, data):
        self.pending += data
        out = b""
        while True:
            start = self.pending.find(PAINT_START)
            if start < 0:
                keep = next((n for n in range(len(PAINT_START) - 1, 0, -1) if self.pending.endswith(PAINT_START[:n])), 0)
                cut = len(self.pending) - keep
                out += self.pending[:cut]
                self.pending = self.pending[cut:]
                return out
            end = self.pending.find(b"\x1b8", start)
            if end < 0:
                out += self.pending[:start]
                self.pending = self.pending[start:]
                return out
            out += self.pending[:start] + self.paint(self.pending[start:end + 2])
            self.pending = self.pending[end + 2:]

    def flush(self):
        out, self.pending = self.pending, b""
        return out

    def paint(self, batch):
        tokens = PAINT_TOKEN.findall(batch)
        header = b""
        segments = []
        style, link, row, col = b"0", b"", None, 1
        for token in tokens:
            cup = re.fullmatch(rb"\x1b\[(\d+);(\d+)H", token)
            if cup:
                row, col = int(cup.group(1)), int(cup.group(2))
                segments.append([row, b"", False])
            if row is None:
                header += token
                continue
            segments[-1][1] += token
            if token.startswith(b"\x1b[") and token.endswith(b"m"):
                style = token[2:-1]
            elif token == b"\x1b[2K":
                segments[-1][2] = True
                self.rows[row] = [(" ", style, b"")] * self.cols
            elif token == b"\x1b[K":
                cells = self.row(row)
                cells[col - 1:] = [(" ", style, b"")] * (len(cells) - col + 1)
            elif token.startswith(b"\x1b]8;"):
                link = b"" if token == LINK_CLOSE else token
            elif not token.startswith(b"\x1b"):
                cells = self.row(row)
                for char in token.decode("utf-8", "replace"):
                    if unicodedata.combining(char) and col > 1:
                        glyph, cell_style, cell_link = cells[col - 2]
                        cells[col - 2] = (glyph + char, cell_style, cell_link)
                        continue
                    width = 2 if unicodedata.east_asian_width(char) in "WF" else 1
                    if col + width - 1 > len(cells):
                        break
                    cells[col - 1] = (char, style, link)
                    if width == 2:
                        cells[col] = CONTINUATION
                    col += width
        trailer = b""
        if segments:
            last = segments[-1][1]
            at = last.rfind(LINK_CLOSE + b"\x1b[0m\x1b8")
            segments[-1][1], trailer = last[:at], last[at:]
        else:
            return batch
        out = header
        for number, raw, erased in segments:
            out += raw if erased else b"\x1b[%d;1H" % number + self.serialize(self.row(number))
        return out + trailer

    @staticmethod
    def serialize(cells):
        out = b""
        style, link = None, b""
        for cell in cells:
            if cell is CONTINUATION:
                continue
            glyph, cell_style, cell_link = cell
            if cell_link != link:
                if link:
                    out += LINK_CLOSE
                out += cell_link
                link = cell_link
            if cell_style != style:
                out += b"\x1b[" + cell_style + b"m"
                style = cell_style
            out += glyph.encode()
        return out + (LINK_CLOSE if link else b"")


_bar_screens = {}


def bar_screen(fd):
    return _bar_screens.setdefault(fd, BarScreen())


def read_pty(fd):
    """Reads PTY output with every bar paint shown as whole rows."""
    screen = bar_screen(fd)
    try:
        data = os.read(fd, 65536)
    except OSError:
        rest = screen.flush()
        if rest:
            return rest
        raise
    return screen.feed(data) if data else screen.flush()


def read_until(fd, data, needle, timeout=5):
    deadline = time.monotonic() + timeout
    while needle not in data:
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {needle!r}; tail={data[-500:]!r}")
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data += read_pty(fd)
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
    _bar_screens.pop(master, None)
    resize(master, rows)
    os.write(ready_w, b"x")
    os.close(ready_w)
    return pid, master


def reap_while_draining(pid, fd, timeout=5):
    """Keep the PTY readable while a killed session leader exits."""
    deadline = time.monotonic() + timeout
    while True:
        got, status = os.waitpid(pid, os.WNOHANG)
        if got:
            return status
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(f"timed out reaping pid {pid} after SIGKILL")
        ready, _, _ = select.select([fd], [], [], min(0.05, remaining))
        if ready:
            try:
                if not read_pty(fd):
                    time.sleep(min(0.01, remaining))
            except OSError:
                time.sleep(min(0.01, remaining))


def capture_pty(argv, env=None, rows=24, timeout=5, raw=False):
    pid, master = spawn(argv, rows, env)
    reader = (lambda fd: os.read(fd, 65536)) if raw else read_pty
    data = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            try:
                chunk = reader(master)
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
                    chunk = reader(master)
                    if not chunk:
                        break
                    data += chunk
                except OSError:
                    break
            os.close(master)
            return os.waitstatus_to_exitcode(status), data
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        reap_while_draining(pid, master)
    finally:
        os.close(master)
    raise AssertionError(f"timed out running {argv!r}; tail={data[-500:]!r}")


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
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        reap_while_draining(pid, fd)
    finally:
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




ANSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
OSC = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def plain(data):
    """Terminal output without control sequences."""
    return ANSI.sub(b"", OSC.sub(b"", data))


def clean_env(env=None):
    result = (os.environ if env is None else env).copy()
    for key in ("STATUSBAR_STATE", "STATUSBAR_SESSION_ID", "STATUSBAR_CONFIG", "STATUSBAR_FIFOS"):
        result.pop(key, None)
    return result


def check_config_file(binary):
    """Standalone validation never starts a session or executes commands."""
    with tempfile.TemporaryDirectory() as directory:
        valid = os.path.join(directory, "draft with spaces.statusbar")
        marker = os.path.join(directory, "command-ran")
        with open(valid, "w") as file:
            file.write(f'[line.a]\ntext = #(command:probe)\n[command.probe]\nrun = touch "{marker}"\n')
        result = subprocess.run([binary, "config", "--check", valid], env=clean_env(), capture_output=True, timeout=5)
        assert result.returncode == 0 and result.stdout == b"" and result.stderr == b"", result
        assert not os.path.exists(marker), "validation executed a configured command"

        invalid = os.path.join(directory, "invalid.statusbar")
        with open(invalid, "w") as file:
            file.write("[line.a]\nleft = old\n")
        result = subprocess.run([binary, "config", "--check", invalid], env=clean_env(), capture_output=True, timeout=5)
        assert result.returncode == 2 and f"{invalid}:2:".encode() in result.stderr, result
        assert b"left, right and rule were removed" in result.stderr and result.stdout == b"", result

        empty = os.path.join(directory, "empty.statusbar")
        open(empty, "w").close()
        result = subprocess.run([binary, "config", "--check", empty], env=clean_env(), capture_output=True, timeout=5)
        assert result.returncode == 2 and b"empty config" in result.stderr, result
        result = subprocess.run([binary, "config", "--check", os.path.join(directory, "missing")], env=clean_env(), capture_output=True, timeout=5)
        assert result.returncode == 1 and b"cannot read" in result.stderr, result
        result = subprocess.run([binary, "config", "--check", valid, "--print"], env=clean_env(), capture_output=True, timeout=5)
        assert result.returncode == 2 and b"choose one of" in result.stderr, result
    print("standalone config validation reports errors without executing commands")


def run_session(binary, config, child, *args, env=None, timeout=15, rows=24, raw=False):
    """Runs a Python child inside a session with an inline config."""
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "session.statusbar")
        with open(path, "w", encoding="utf-8") as file:
            file.write(config)
        return capture_pty([binary, "-c", path, "--", sys.executable, "-c", child, binary, *args],
                           env=clean_env(env), rows=rows, timeout=timeout, raw=raw)


def between(text, start, end):
    """The output after marker `start` and before marker `end`."""
    first = text.index(start)
    return text[first:text.index(end, first)]


CHILD_PRELUDE = r"""
import os, signal, stat, subprocess, sys, tempfile, time
b = sys.argv[1]
def run(*args, code=0, input=None, env=None):
    p = subprocess.run([b, *args], input=input, capture_output=True, env=env, timeout=6)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout.decode().strip()
def settle():
    time.sleep(.15)
def mark(name):
    settle()
    print(name, flush=True)
"""


def check_set(binary):
    config = """[line.build]
default = idle
text = "BUILD[#(value)|#(status)]"
done = "DONE[#(value)]"
failed = ""
[line.other]
text = "OTHER[#(value)]"
"""
    child = CHILD_PRELUDE + r"""
mark('STEP_START')
run('set', 'build'); mark('STEP_UNCHANGED')
run('set', 'build', '--status', 'running'); mark('STEP_STATUS')
run('set', 'build', ''); mark('STEP_EMPTY')
run('set', 'build', 'Build passed', '--status', 'success'); mark('STEP_BOTH')
run('set', 'build', '--reset'); mark('STEP_RESET')
run('set', 'build', '--reset', '--status', 'normal'); mark('STEP_RESET_STATUS')
run('set', 'build', 'a', 'b', '--status', 'failed'); mark('STEP_FAILED')
run('set', 'build', '--status', 'running'); mark('STEP_RUNNING')
run('set', '1', '-'); settle()
run('set', '--', '1', '--dash'); settle()
run('set', 'build', '#(value) #[fg=red]x ##'); settle()
run('set', 'other', '\x1b[31mred\x1b[0m'); settle()
for args in (['build', 'x', '--reset'], ['build', '', '--reset'], ['build', '--status', 'fail'],
             ['bad.name', 'x'], ['0', 'x'], ['build', 'x' * 1025]):
    run('set', *args, code=2)
for args in (['missing', 'x'], ['99', '--status', 'done']):
    run('set', *args, code=1)
mark('SET_OK')
"""
    code, data = run_session(binary, config, child)
    assert code == 0 and b"SET_OK" in data, data[-3000:]
    text = plain(data)
    assert b"BUILD[idle|normal]" in text[:text.index(b"STEP_START")], text[-3000:]
    # A set without attributes changes nothing, so nothing is repainted.
    assert b"BUILD[" not in between(text, b"STEP_START", b"STEP_UNCHANGED"), text[-3000:]
    assert b"BUILD[idle|running]" in between(text, b"STEP_UNCHANGED", b"STEP_STATUS"), text[-3000:]
    assert b"BUILD[|running]" in between(text, b"STEP_STATUS", b"STEP_EMPTY"), text[-3000:]
    assert b"DONE[Build passed]" in between(text, b"STEP_EMPTY", b"STEP_BOTH"), text[-3000:]
    # A combined change never shows an intermediate state.
    assert b"BUILD[Build passed|running]" not in text and b"DONE[]" not in text, text[-3000:]
    assert b"DONE[idle]" in between(text, b"STEP_BOTH", b"STEP_RESET"), text[-3000:]
    assert b"BUILD[idle|normal]" in between(text, b"STEP_RESET", b"STEP_RESET_STATUS"), text[-3000:]
    # The failed template is explicitly empty; the value survives it.
    assert b"BUILD[a b|running]" in between(text, b"STEP_FAILED", b"STEP_RUNNING"), text[-3000:]
    assert b"BUILD[-|running]" in text and b"BUILD[--dash|running]" in text, text[-3000:]
    assert b"BUILD[#(value) #[fg=red]x ##|running]" in text, text[-3000:]
    assert b"\x1b[0;38;5;1mred" in data and b"OTHER[red]" in text, data[-3000:]

    env = clean_env()
    for args in (["prompt", "x"], ["prompt", "--status", "done"], ["5", "--reset"], ["prompt", ""]):
        result = subprocess.run([binary, "set", *args], env=env, capture_output=True)
        assert result.returncode == 0 and not result.stdout and not result.stderr, result
    for args in (["prompt", "x", "--reset"], ["a.b", "x"], ["prompt", "--status", "fail"]):
        result = subprocess.run([binary, "set", *args], env=env, capture_output=True)
        assert result.returncode == 2 and not result.stdout, result
    print("set changes only supplied attributes, atomically, and is quiet outside a session")


def check_init_invocation(binary):
    env = os.environ.copy()
    env["STATUSBAR_STATE"] = "/statusbar-session-indicator"
    with tempfile.TemporaryDirectory() as directory:
        stable = os.path.join(directory, "statusbar")
        os.symlink(binary, stable)

        absolute = subprocess.run(
            [stable, "init", "zsh"], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        )
        assert f"command '{stable}' set prompt".encode() in absolute.stdout
        assert f"command '{binary}' set".encode() not in absolute.stdout

        path_env = env.copy()
        path_env["PATH"] = directory + os.pathsep + path_env.get("PATH", "")
        by_name = subprocess.run(
            ["statusbar", "init", "zsh"], env=path_env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        )
        assert b"command 'statusbar' set prompt" in by_name.stdout

    outside_env = env.copy()
    outside_env.pop("STATUSBAR_STATE")
    outside_env["STATUSBAR_LINES"] = "2"  # obsolete variable is ignored
    outside = subprocess.run([binary, "init", "zsh"], env=outside_env,
                             capture_output=True, check=True)
    assert outside.stdout == b"", outside

    print("shell init preserves upgrade-safe invocation paths")


def check_stdin_config(binary):
    config = "interval = 0.1\nstyle = fg=blue\n[line.one]\ntext = PIPE_ONE\n[line.two]\ntext = #(command:two)\n[command.two]\nrun = printf PIPE_TWO\n"
    q = shlex.quote
    child = r'''printf '__READY__:%s:%s\n' "$(stty size)" "${STATUSBAR_LINES-unset}"
while IFS= read -r value; do
    case "$value" in
        SIZE) printf '__SIZE__:%s\n' "$(stty size)" ;;
        RELOAD) printf '[line.one]\ntext = RELOADED\n' | "$1" config ;;
        EXIT) exit 7 ;;
        *) printf '__INPUT__:%s\n' "$value" ;;
    esac
done
'''
    command = shlex.join([binary, "--config=-", "--", "/bin/sh", "-c", child, "sh", binary])
    env = clean_env()
    env["STATUSBAR_CONFIG"] = "/does/not/exist/statusbar-config"
    env["STATUSBAR_LINES"] = "9"  # obsolete parent value must not reach the child
    script = f"printf %s {q(config)} | {command}"
    pid, master = spawn(["/bin/sh", "-c", script], env=env)
    reaped = False
    try:
        data = read_until(master, b"", b"__READY__:22 80:unset")
        data = read_until(master, data, b"PIPE_TWO")
        assert b"PIPE_ONE" in data, data
        os.write(master, b"keyboard works\n")
        data = read_until(master, data, b"__INPUT__:keyboard works")
        resize(master, 30)
        time.sleep(0.15)
        os.write(master, b"SIZE\n")
        data = read_until(master, data, b"__SIZE__:28 80")
        os.write(master, b"RELOAD\n")
        data = read_until(master, data, b"RELOADED")
        os.write(master, b"EXIT\n")
        status = reap_while_draining(pid, master)
        reaped = True
        assert os.waitstatus_to_exitcode(status) == 7, data
        flags = termios.tcgetattr(master)[3]
        assert flags & termios.ICANON and flags & termios.ECHO, flags
    finally:
        if reaped:
            os.close(master)
        else:
            stop(pid, master)

    # Here-documents use the same input path and leave the child on a terminal.
    script = shlex.join([binary, "-c", "-", "--", "/bin/sh", "-c", "test -t 0 && printf HEREDOC_OK"]) + " <<'CONFIG'\n" + config + "CONFIG\n"
    code, data = capture_pty(["/bin/sh", "-c", script], env=clean_env())
    assert code == 0 and b"HEREDOC_OK" in data, data

    # A config that cannot be used still reaches the shell, with the
    # built-in config and a warning line. Keyboard input still works.
    for text, message in [
        ("", b"stdin contains no config"),
        ("# no lines\n", b"config needs at least one [line.NAME] section"),
        ("[line.a]\nunknown = value\n", b"line 2: unknown line key"),
        ("[line.1]\nleft = old\n", b"line 1: line names cannot be all digits"),
    ]:
        script = f"printf %s {q(text)} | " + shlex.join([binary, "--config", "-", "--", "/bin/sh", "-c", "test -t 0 && printf CHILD_STARTED; exit 4"])
        code, data = capture_pty(["/bin/sh", "-c", script], env=clean_env())
        assert code == 4 and b"CHILD_STARTED" in data, data
        rows = painted(data)
        assert any(message in row for row in rows), rows
        assert any(row.startswith(b"\xe2\x94\x80\xe2\x94\x80") for row in rows), rows

    for text, message in [
        (b"[line.a]\n#" + b"x" * 65536, b"limit 65536 bytes"),
        (config.encode(), b"cannot open /dev/tty for keyboard input"),
    ]:
        result = subprocess.run([binary, "--config", "-"], input=text, capture_output=True, start_new_session=True, timeout=5, env=clean_env())
        assert result.returncode != 0 and message in result.stderr, result

    # --config - does not make redirected stdout an interactive terminal.
    with tempfile.TemporaryDirectory() as folder:
        output = os.path.join(folder, "output")
        script = f"printf %s {q(config)} | {q(binary)} --config - > {q(output)}"
        code, data = capture_pty(["/bin/sh", "-c", script], env=clean_env())
        assert code == 1 and b"stdin and stdout must be a terminal" in data, data
        assert os.path.getsize(output) == 0

    for flag in ["--exec", "--lines", "--interval", "--style", "-e", "-n", "-i", "-s"]:
        result = subprocess.run([binary, flag, "1"], capture_output=True, timeout=5)
        assert result.returncode == 2, (flag, result)
    print("stdin configs, recovery, keyboard input, resize, reload, and terminal restoration passed")


def painted_rows(data):
    """Every text painted to each bar row, in order."""
    rows = {}
    for match in re.finditer(rb"\x1b\[(\d+);1H(.*?)(?=\x1b\[\d+;1H|\x1b8)", data, re.S):
        text = plain(match.group(2))
        if text.strip():
            rows.setdefault(int(match.group(1)), []).append(text)
    return rows


def painted(data):
    """All painted bar row texts, without trailing spaces."""
    return [text.rstrip() for texts in painted_rows(data).values() for text in texts]


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

    script = "printf '[line.a]\\ntext = bar\\n' | " + shlex.join([
        binary, "--config", "-",
        "--", "/bin/sh", "-c", 'printf %s "$1"', "sh", payload.decode("ascii"),
    ])
    argv = ["/bin/sh", "-c", script]
    code, data = capture_pty(argv, env=clean_env())
    assert code == 0, data
    assert expected in data, data[-6000:]
    print("OSC 7 forwarding and ordered terminal titles passed")


PROMPT_CONFIG = '[line.prompt]\ntext = "P[#(value)]"\n[line.other]\ntext = "O[#(value)]"\n'
FAKE_STARSHIP = {
    "zsh": "#!/bin/sh\ncase $STARSHIP_TEST_MODE in\n  multi) printf 'bar%%%%literal\\nprompt' ;;\n  one) printf 'one%%%%literal' ;;\nesac\n",
    "other": "#!/bin/sh\ncase $STARSHIP_TEST_MODE in\n  multi) printf 'bar%%literal\\nprompt' ;;\n  one) printf 'one%%literal' ;;\nesac\n",
}


def shell_session(binary, config, argv, env, timeout=8):
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "shell.statusbar")
        with open(path, "w", encoding="utf-8") as file:
            file.write(config)
        return capture_pty([binary, "-c", path, "--", *argv], env=clean_env(env), timeout=timeout)


def fake_starship(directory, kind):
    starship = os.path.join(directory, "starship")
    with open(starship, "w", encoding="utf-8") as file:
        file.write(FAKE_STARSHIP[kind])
    os.chmod(starship, 0o755)
    env = os.environ.copy()
    env["PATH"] = directory + os.pathsep + env.get("PATH", "")
    return env


def check_prompt_split(binary, argv_for, name):
    """Starship details move into the named line; one-line prompts and
    layouts without the line keep the full prompt in the terminal."""
    for line, option in (("P", []), ("O", ["--starship-line", "other"])):
        code, data = shell_session(binary, PROMPT_CONFIG, argv_for("multi", option), None)
        assert code == 0, data
        assert f"{line}[bar%literal]".encode() in plain(data), plain(data)[-2000:]
        assert b"prompt" in data
    code, data = shell_session(binary, PROMPT_CONFIG, argv_for("one", []), None)
    assert code == 0 and b"P[]" in plain(data), plain(data)[-2000:]
    assert b"P[one" not in plain(data), data
    code, data = shell_session(binary, '[line.other]\ntext = "O[#(value)]"\n', argv_for("multi", []), None)
    assert code == 0 and b"O[]" in plain(data), plain(data)[-2000:]
    assert b"O[bar" not in plain(data), data
    print(f"{name} Starship split passed")


def check_zsh(binary):
    zsh = shutil.which("zsh")
    if zsh is None:
        print("zsh -f integration skipped: zsh unavailable")
        return
    env = os.environ.copy()
    env["STATUSBAR_STATE"] = "/statusbar-session-indicator"
    quoted_binary = shlex.quote(binary)
    for bad in ("a.b", "0", "a b", ""):
        result = subprocess.run([binary, "init", "zsh", "--starship-line", bad], env=env, capture_output=True)
        assert result.returncode == 2 and result.stdout == b"", (bad, result)
    for good in ("prompt", "5"):
        result = subprocess.run([binary, "init", "zsh", "--starship-line", good], env=env, capture_output=True)
        assert result.returncode == 0 and b"__statusbar_report_cwd" in result.stdout, result

    with tempfile.TemporaryDirectory() as directory:
        path_env = fake_starship(directory, "zsh")

        def argv_for(mode, option):
            options = " ".join(shlex.quote(part) for part in option)
            script = (
                f'export PATH={shlex.quote(path_env["PATH"])}; export STARSHIP_TEST_MODE={mode}; '
                f'eval "$({quoted_binary} init zsh {options})"; __statusbar_prompt; print; sleep 0.3'
            )
            return [zsh, "-f", "-c", script]
        check_prompt_split(binary, argv_for, "zsh")
        code, data = shell_session(binary, '[line.other]\n', argv_for("multi", []), None)
        assert b"bar%%literal\r\nprompt" in data, data
        code, data = shell_session(binary, PROMPT_CONFIG, argv_for("one", []), None)
        assert b"one%%literal" in data, data


def check_fish(binary):
    fish = shutil.which("fish")
    if fish is None:
        print("fish integration skipped: fish unavailable")
        return
    quoted_binary = shlex.quote(binary)
    with tempfile.TemporaryDirectory() as directory:
        path_env = fake_starship(directory, "other")

        def argv_for(mode, option):
            options = " ".join(shlex.quote(part) for part in option)
            script = (
                f"set -gx PATH {shlex.quote(path_env['PATH'])}; set -gx STARSHIP_TEST_MODE {mode}; "
                f"{quoted_binary} init fish {options} | source; fish_prompt; echo; sleep 0.3"
            )
            return [fish, "-N", "-c", script]
        check_prompt_split(binary, argv_for, "fish")
        code, data = shell_session(binary, '[line.other]\n', argv_for("multi", []), None)
        assert b"bar%literal\r\nprompt" in data, data


def check_nu(binary):
    nu = shutil.which("nu")
    if nu is None:
        print("Nushell integration skipped: nu unavailable")
        return
    with tempfile.TemporaryDirectory() as directory:
        os.symlink(binary, os.path.join(directory, "statusbar"))
        path_env = fake_starship(directory, "other")
        sample = os.path.join(os.path.dirname(__file__), "..", "samples", "statusbar.nu")
        with open(sample, "rb") as file:
            integration = file.read()
        assert b"set prompt --" in integration
        scripts = {}
        for target in ("prompt", "other"):
            script_path = os.path.join(directory, f"statusbar-{target}.nu")
            with open(script_path, "wb") as file:
                file.write(integration.replace(b"set prompt --", f"set {target} --".encode()))
            scripts[target] = script_path

        def argv_for(mode, option):
            target = option[1] if option else "prompt"
            script = (
                f'$env.PATH = ({json.dumps(path_env["PATH"])} | split row (char esep)); '
                f'$env.STARSHIP_TEST_MODE = "{mode}"; '
                '$env.CMD_DURATION_MS = "0823"; $env.LAST_EXIT_CODE = 0; '
                f'source {scripts[target]}; let prompt = (do $env.PROMPT_COMMAND); print $prompt; sleep 300ms'
            )
            return [nu, "-n", "-c", script]
        check_prompt_split(binary, argv_for, "Nushell")

        target = os.path.join(directory, "space % café")
        os.mkdir(target)
        env = os.environ.copy()
        env["STATUSBAR_STATE"] = "/statusbar-session-indicator"
        cwd_script = (
            f'source {scripts["prompt"]}; source {scripts["prompt"]}; cd "{target}"; '
            'print ($env.config.hooks.pre_prompt | length); '
            'do ($env.config.hooks.pre_prompt | last)'
        )
        code, data = capture_pty([nu, "-n", "-c", cwd_script], env)
        assert code == 0 and b"1\r\n" in data, data
        report = re.search(rb"\x1b\]7;file://(/.*?)\x07", data)
        assert report is not None, data
        assert urllib.parse.unquote_to_bytes(report[1].decode()) == target.encode(), data
    print("Nushell integration passed")


def check_init_features(binary):
    env = os.environ.copy()
    env["STATUSBAR_STATE"] = "/statusbar-session-indicator"
    for shell in ("zsh", "fish"):
        for flags in (("--starship=false", "--report-cwd=false"),):
            result = subprocess.run([binary, "init", shell, *flags], env=env, capture_output=True)
            assert result.returncode == 0 and result.stdout == b"", result
        for flags in (("--starship=false", "--starship-line=prompt"), ("--report-cwd=wrong",), ("--starship-slot=3",)):
            result = subprocess.run([binary, "init", shell, *flags], env=env, capture_output=True)
            assert result.returncode == 2 and result.stdout == b"", result
        result = subprocess.run([binary, "init", shell, "--report-cwd=false"], env=env, capture_output=True)
        assert result.returncode == 0 and b"__statusbar_report_cwd" not in result.stdout

        executable = shutil.which(shell)
        if executable is None:
            continue
        # Without Starship, default initialization still works in a one-line
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
            cfg.write(f"""[line.a]
text = PREFIX #[track]#(command:value)#[notrack] BETWEEN #[track]#(command:second)#[notrack] SUFFIX#(fill:.)RIGHT
[command.value]
run = cat {shlex.quote(value_path)}
interval = 0.1
[command.second]
run = cat {shlex.quote(second_path)}
interval = 0.1
""")
            cfg.write("[highlight]\npulses = 1\n")
        exit_on_request = 'while IFS= read -r command; do [ "$command" = EXIT ] && exit 0; done'
        pid, master = spawn([binary, "-c", config_path, "--", "/bin/sh", "-c", exit_on_request])
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
            cfg.write(f"""[line.a]
text = VALUE #[track]#(command:value)#[notrack]
[command.value]
run = printf 'cols:%s:' \"$STATUSBAR_COLUMNS\"; cat {shlex.quote(value_path)}
interval = 0.2
""")
        exit_on_request = 'while IFS= read -r command; do [ "$command" = EXIT ] && exit 0; done'
        pid, master = spawn([binary, "-c", config_path, "--", "/bin/sh", "-c", exit_on_request])
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


def check_resize_command_runs(binary):
    with tempfile.TemporaryDirectory(prefix="statusbar-resize-") as folder:
        runs = os.path.join(folder, "runs")
        config_path = os.path.join(folder, "config")
        with open(config_path, "w") as cfg:
            cfg.write(f'''[line.a]
text = #(command:value)
[command.value]
run = echo "$STATUSBAR_COLUMNS" >> {shlex.quote(runs)}; printf 'cols:%s' "$STATUSBAR_COLUMNS"
interval = 60
''')
        child = 'while IFS= read -r command; do [ "$command" = EXIT ] && exit 0; done'
        pid, master = spawn([binary, "-c", config_path, "--", "/bin/sh", "-c", child])
        try:
            read_until(master, b"", b"cols:80")
            for rows in (30, 30):
                resize(master, rows)
                os.kill(pid, signal.SIGWINCH)
                read_until(master, b"", b"cols:80")
                # Give an accidentally scheduled process time to record a run.
                time.sleep(0.15)
                with open(runs) as file:
                    assert file.read().splitlines() == ["80"]
            resize(master, 30, 60)
            read_until(master, b"", b"cols:60")
            with open(runs) as file:
                assert file.read().splitlines() == ["80", "60"]
        finally:
            stop(pid, master)
    print("commands rerun only for width changes")


def check_datetime_and_terminal_properties(binary):
    with tempfile.TemporaryDirectory(prefix="statusbar-template-properties-") as folder:
        config_path = os.path.join(folder, "config")
        replacement_path = os.path.join(folder, "replacement")
        with open(config_path, "w") as cfg:
            cfg.write("[line.a]\ntext = STAMP#(datetime:%Y) WINDOW#(terminal:rows)x#(terminal:cols) SHELL#(terminal:content_rows)\n[line.b]\ntext = second\n")
        with open(replacement_path, "w") as cfg:
            cfg.write("[line.a]\ntext = STAMP#(datetime:%Y) WINDOW#(terminal:rows)x#(terminal:cols) SHELL#(terminal:content_rows)\n[line.b]\ntext = second\n[line.c]\ntext = third\n")
        child = (
            'while IFS= read -r action; do case "$action" in '
            f'PUSH) printf "payload\\n" | {shlex.quote(binary)} push extra ;; '
            f'POP) {shlex.quote(binary)} pop ;; '
            f'RELOAD) {shlex.quote(binary)} config < {shlex.quote(replacement_path)} ;; '
            'EXIT) exit 0 ;; esac; done'
        )
        pid, master = spawn([binary, "-c", config_path, "--", "/bin/sh", "-c", child])
        try:
            initial = read_until(master, b"", b"WINDOW24x80 SHELL22")
            assert re.search(rb"STAMP[0-9]{4} WINDOW24x80 SHELL22", initial), initial

            resize(master, 30, 60)
            os.kill(pid, signal.SIGWINCH)
            read_until(master, b"", b"WINDOW30x60 SHELL28")

            os.write(master, b"PUSH\n")
            read_until(master, b"", b"WINDOW30x60 SHELL27")
            os.write(master, b"POP\n")
            read_until(master, b"", b"WINDOW30x60 SHELL28")
            os.write(master, b"RELOAD\n")
            read_until(master, b"", b"WINDOW30x60 SHELL27")
            os.write(master, b"EXIT\n")
        finally:
            stop(pid, master)
    print("datetime and terminal size templates follow resize, pushed rows, and reload")


def check_adaptive_palette(binary):
    """Emulate terminal queries, including a subsequent child-owned query."""
    with tempfile.TemporaryDirectory(prefix="statusbar-palette-") as folder:
        value_path = os.path.join(folder, "value")
        config_path = os.path.join(folder, "config")
        with open(value_path, "w") as value:
            value.write("one\n")
        with open(config_path, "w") as cfg:
            cfg.write(f"""[line.a]
text = LABEL #[track]#[fg=red,bg=blue]#(command:value) #[default]D#[notrack] END
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
        config_path = os.path.join(folder, "bar.statusbar")
        with open(config_path, "w") as config_file:
            config_file.write("[line.a]\ntext = LOG_BAR\n")
        for command in (["run", "--log", path], ["--log", path]):
            code, data = capture_pty([
                binary, *command, "-c", config_path, "--",
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


def check_config_snapshots(binary):
    original = b'# original comment\n[line.a]\ntext = "initial text"'  # No final newline.
    replacement = b'# live replacement\n[line.a]\ntext = next\n[line.b]\ntext = "#(fill: )#(datetime:%H:%M)"\n'
    clean_env = os.environ.copy()
    clean_env.pop("STATUSBAR_STATE", None)
    clean_env.pop("STATUSBAR_SESSION_ID", None)
    clean_env["STATUSBAR_CONFIG"] = "/does/not/exist/statusbar-config"
    builtin = subprocess.run([binary, "config", "--default"], env=clean_env, capture_output=True, check=True).stdout
    result = subprocess.run([binary, "config", "--print", "default"], input=b"invalid", env=clean_env, capture_output=True)
    assert result.returncode == 0 and result.stdout == builtin, result
    with tempfile.TemporaryDirectory() as folder:
        invalid_path = os.path.join(folder, "invalid.statusbar")
        with open(invalid_path, "wb") as config_file:
            config_file.write(b"[broken\n")
        path_env = clean_env.copy()
        path_env["STATUSBAR_CONFIG"] = invalid_path
        result = subprocess.run([binary, "config", "--path"], env=path_env, capture_output=True)
        assert result.returncode == 0 and result.stdout == os.fsencode(invalid_path) + b"\n", result
        assert result.stderr == b"", result
        path_env.pop("STATUSBAR_CONFIG")
        path_env["XDG_CONFIG_HOME"] = folder
        result = subprocess.run([binary, "config", "--path"], env=path_env, capture_output=True)
        assert result.returncode == 0 and result.stdout == b"built-in\n", result
    for args in (["--print"], ["--print", "current"], ["--print", "startup"]):
        result = subprocess.run([binary, "config", *args], env=clean_env, capture_output=True)
        assert result.returncode == 2 and not result.stdout and b"requires a running" in result.stderr, result
    for args in (["--print", "unknown"], ["startup"], ["--default", "current"], ["--print", "current", "--path"], ["--print", "--default"]):
        result = subprocess.run([binary, "config", *args], env=clean_env, capture_output=True)
        assert result.returncode == 2 and not result.stdout, result

    child = r'''
import base64, json, os, stat, subprocess, sys, time
binary, config_path, original_hex, replacement_hex, metadata_path = sys.argv[1:]
original = bytes.fromhex(original_hex)
replacement = bytes.fromhex(replacement_hex)
def show(*args):
    r = subprocess.run([binary, 'config', *args], input=b'invalid stdin', capture_output=True)
    assert r.returncode == 0, r
    return r.stdout
def current_is(expected):
    deadline = time.monotonic() + 3
    while show('--print') != expected:
        assert time.monotonic() < deadline
        time.sleep(.01)
assert show('--print', 'startup') == original
assert show('--print') == original
assert show('--print', 'current') == original
if config_path != '-':
    open(config_path, 'wb').write(b'invalid modified file')
    os.unlink(config_path)
assert show('--print', 'startup') == original
assert show('--print') == original
assert show('--default') == show('--print', 'default')
assert stat.S_IMODE(os.stat(os.environ['STATUSBAR_STATE']).st_mode) == 0o600
subprocess.run([binary, 'set', 'a', 'MANUAL_OVERRIDE'], check=True)
assert show('--print') == original
subprocess.run([binary, 'config'], input=replacement, check=True)
current_is(replacement)
assert show('--print', 'startup') == original
assert show('--print', 'current') == replacement
assert stat.S_IMODE(os.stat(os.environ['STATUSBAR_STATE']).st_mode) == 0o600
# A correctly authenticated but malformed replacement must retain the snapshot.
envelope = b'1;' + os.environ['STATUSBAR_SESSION_ID'].encode() + b';[broken\n'
os.write(1, b'\x1b]3110;STATUSBAR;CONFIG;' + base64.b64encode(envelope) + b'\x1b\\')
time.sleep(.1)
assert show('--print') == replacement
assert show('--print', 'startup') == original
# Restoring startup is a normal config replacement.
subprocess.run([binary, 'config'], input=show('--print', 'startup'), check=True)
current_is(original)
# Nested sessions have their own snapshots; the outer session is unaffected.
nested_text = b'[line.a]\ntext = nested\n'
code = "import subprocess,sys; r=subprocess.run([sys.argv[1],'config','--print','startup'],capture_output=True); assert r.returncode == 0 and r.stdout == bytes.fromhex(sys.argv[2])"
r = subprocess.run([binary, '--config', '-', '--', sys.executable, '-c', code, binary, nested_text.hex()], input=nested_text)
assert r.returncode == 0
assert show('--print') == original
wrong = os.environ.copy()
wrong['STATUSBAR_SESSION_ID'] = '0' * 32
r = subprocess.run([binary, 'config', '--print'], env=wrong, capture_output=True)
assert r.returncode != 0 and not r.stdout
json.dump({k: os.environ[k] for k in ('STATUSBAR_STATE', 'STATUSBAR_SESSION_ID')}, open(metadata_path, 'w'))
print('SNAPSHOTS_OK', flush=True)
'''
    with tempfile.TemporaryDirectory() as folder:
        for mode in ("file", "stdin"):
            config_path = os.path.join(folder, "initial.statusbar")
            metadata_path = os.path.join(folder, mode + ".json")
            with open(config_path, "wb") as config_file:
                config_file.write(original)
            selected = config_path if mode == "file" else "-"
            argv = [binary, "--config", selected, "--", sys.executable, "-c", child,
                    binary, selected, original.hex(), replacement.hex(), metadata_path]
            if mode == "stdin":
                argv = ["/bin/sh", "-c", f"cat {shlex.quote(config_path)} | " + shlex.join(argv)]
            code, data = capture_pty(argv, env=clean_env, timeout=12)
            assert code == 0 and b"SNAPSHOTS_OK" in data, data[-3000:]
            with open(metadata_path) as metadata:
                stale = json.load(metadata)
            assert not os.path.exists(stale["STATUSBAR_STATE"])
            result = subprocess.run([binary, "config", "--print"], env={**clean_env, **stale}, capture_output=True)
            assert result.returncode != 0 and not result.stdout, result
    print("startup/current config snapshots preserve bytes, isolate sessions, and clean up")


def check_osc_config(binary):
    initial = "[line.a]\ntext = ORIGINAL\n"
    replacement = "[line.a]\ntext = REPLACED_ONE\n[line.b]\ntext = REPLACED_TWO\n"
    direct = '[line.a]\ntext = "DIRECT; Καλημέρα"\n'
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
        for args in [
            ["--config", initial_path],
            ["-c", initial_path],
            ["--default", "--config", initial_path],
            [replacement_path, "--default"],
            [replacement_path, "--config", initial_path],
            [replacement_path, initial_path],
            [replacement_path],
            ["-"],
            ["--load", replacement_path],
        ]:
            result = subprocess.run([binary, "config", *args], capture_output=True)
            assert result.returncode == 2 and not result.stdout, result
        no_session = subprocess.run(
            [binary, "config"], input=replacement.encode(),
            capture_output=True, check=False,
        )
        assert no_session.returncode == 2 and not no_session.stdout
        assert b"not inside a compatible statusbar session" in no_session.stderr
        incompatible = subprocess.run(
            [binary, "config", replacement_path, "--path"],
            capture_output=True, check=False,
        )
        assert incompatible.returncode == 2 and not incompatible.stdout
        oversized_path = os.path.join(folder, "oversized")
        with open(oversized_path, "w") as config_file:
            config_file.write("#" + "x" * 24522 + "\n")
        oversized_env = os.environ.copy()
        oversized_env["STATUSBAR_SESSION_ID"] = "0" * 32
        with open(oversized_path, "rb") as source:
            oversized = subprocess.run(
                [binary, "config"], stdin=source, env=oversized_env,
                capture_output=True, check=False,
            )
        assert oversized.returncode != 0 and not oversized.stdout
        for content in [b"", b"x" * 24524, b"[broken\n"]:
            rejected = subprocess.run(
                [binary, "config"], input=content, env=oversized_env,
                capture_output=True, timeout=3,
            )
            assert rejected.returncode != 0 and not rejected.stdout
            assert b"stdin" in rejected.stderr, rejected
        ignored = subprocess.run(
            [binary, "config", "--default"], input=b"[broken\n", capture_output=True,
        )
        assert ignored.returncode == 0 and ignored.stdout
        child = r'''
import base64, os, subprocess, sys, time
binary, replacement, direct, nested_token_path, rejected_command_path = sys.argv[1:]
help_result = subprocess.run([binary, "config"], capture_output=True)
explicit_help = subprocess.run([binary, "config", "--help"], capture_output=True)
assert help_result.returncode == 0 and help_result.stdout == explicit_help.stdout, help_result
assert b"EXAMPLES" in help_result.stdout and b"statusbar config < my.statusbar" in help_result.stdout
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
        rejected = f"[line.a]\ntext = #(command:bad)\n[command.bad]\nrun = touch {rejected_command_path}\n"
        emit(rejected, "0" * 32)
        print("__BAD__", flush=True)
    elif command == "LOAD":
        with open(replacement, "rb") as source:
            result = subprocess.run([binary, "config"], stdin=source, capture_output=True)
        assert not result.stdout and result.returncode == 0, result
        print(f"__LOAD__:{result.returncode}", flush=True)
    elif command == "STDIN":
        result = subprocess.run([binary, "config"], input=b'[line.a]\ntext = FROM_STDIN\n', capture_output=True)
        assert not result.stdout and result.returncode == 0, result
        print("__STDIN__", flush=True)
    elif command == "PIPE":
        producer = subprocess.Popen([binary, "config", "--default"], stdout=subprocess.PIPE)
        result = subprocess.run([binary, "config"], stdin=producer.stdout, capture_output=True)
        producer.stdout.close()
        assert producer.wait() == 0 and result.returncode == 0 and not result.stdout, result
        print("__PIPE__", flush=True)
    elif command == "DIRECT":
        emit(direct)
        print("__DIRECT__", flush=True)
    elif command == "ORDER":
        first = "[line.a]\ntext = ORDER_ONE\n[line.b]\ntext = ORDER_TWO\n"
        final = "[line.a]\ntext = FINAL_ONE\n[line.b]\ntext = FINAL_TWO\n"
        # Removed slot variables are ordinary output now.
        slot = b"\x1b]1337;SetUserVar=StatusBarSlot4=S0VFUA==\x1b\\"
        os.write(1, frame(first) + slot + frame(final))
        print("__ORDER__", flush=True)
    elif command == "SAVED":
        os.write(1, b"\x1b7")
        emit('[line.a]\ntext = AFTER_RESTORE\n')
        time.sleep(.01)
        os.write(1, b"\x1b8")
        print("__SAVED__", flush=True)
    elif command == "HELD":
        os.write(1, b"\x1b7")
        emit('[line.a]\ntext = AFTER_PAUSE\n')
        print("__HELD__", flush=True)
    elif command == "NESTED":
        code = 'import os,sys; open(sys.argv[1], "w").write(os.environ["STATUSBAR_SESSION_ID"])'
        result = subprocess.run([binary, "-c", replacement, "--", sys.executable, "-c", code, nested_token_path])
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
            os.write(master, b"STDIN\n")
            data = read_until(master, data, b"FROM_STDIN", timeout=5)
            data = read_until(master, data, b"__STDIN__", timeout=5)
            os.write(master, b"PIPE\n")
            data = read_until(master, data, b"__PIPE__", timeout=5)
            os.write(master, b"DIRECT\n")
            data = read_until(master, data, "DIRECT; Καλημέρα".encode(), timeout=5)
            data = read_until(master, data, b"__DIRECT__", timeout=3)
            os.write(master, b"ORDER\n")
            data = read_until(master, data, b"FINAL_TWO", timeout=5)
            data = read_until(master, data, b"SetUserVar=StatusBarSlot4=S0VFUA==", timeout=5)
            data = read_until(master, data, b"__ORDER__", timeout=3)
            os.write(master, b"NESTED\n")
            data = read_until(master, data, b"__NESTED__:0:True", timeout=5)
            # A request is held while the child owns the saved cursor, and
            # applies once it is restored or the output pauses.
            os.write(master, b"SAVED\n")
            data = read_until(master, data, b"__SAVED__", timeout=3)
            data = read_until(master, data, b"AFTER_RESTORE", timeout=3)
            os.write(master, b"HELD\n")
            data = read_until(master, data, b"__HELD__", timeout=3)
            data = read_until(master, data, b"AFTER_PAUSE", timeout=3)
            assert b"3110;STATUSBAR" not in data
            with open(log_path) as log_file:
                logged = log_file.read()
            assert logged.count("OSC config held: child cursor is saved") == 2, logged
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
text = ''.join('[line.r%d]\ntext = ROW%d\n' % (n, n) for n in range(1, 6))
envelope = b'1;' + os.environ['STATUSBAR_SESSION_ID'].encode() + b';' + text.encode()
frame = b'\x1b]3110;STATUSBAR;CONFIG;' + base64.b64encode(envelope) + b'\x1b\\'
os.write(1, frame + b'\nAFTER_CONFIG\n')
time.sleep(.3)
'''
    config = "[line.a]\ntext = BEFORE_BAR\n[line.b]\n"
    script = f"printf %s {shlex.quote(config)} | " + shlex.join([binary, "-c", "-", "--", sys.executable, "-c", child])
    pid, master = spawn(["/bin/sh", "-c", script], rows=24)
    try:
        data = read_until(master, b"", b"AFTER_CONFIG", timeout=5)
        assert data.index(b"\x1b7\x1b[1;19r\x1b8") < data.index(b"AFTER_CONFIG"), data
    finally:
        stop(pid, master)
    pastel = os.path.abspath("samples/themes/pastel-powerline.statusbar")
    multi = os.path.abspath("samples/themes/multi-line.statusbar")
    script = r'''
printf THEME_GROWTH_READY
IFS= read -r command
"$1" config < "$2"
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


def check_background_job_exit(binary):
    # The job ignores SIGHUP and keeps the pty open after the shell exits.
    script = "(trap '' HUP; exec sleep 10) & printf LAST_WORDS; exit 3"
    started = time.monotonic()
    command = "printf '[line.a]\\ntext = BAR\\n' | " + shlex.join([binary, "-c", "-", "--", "/bin/sh", "-c", script])
    code, data = capture_pty(["/bin/sh", "-c", command], timeout=4)
    assert code == 3, (code, data[-500:])
    assert b"LAST_WORDS" in data, data[-500:]
    assert time.monotonic() - started < 3
    print("a background job holding the pty does not keep the session open")


def check_background_push_tty_output(binary):
    zsh = shutil.which("zsh")
    if not zsh:
        return
    config = os.path.abspath("samples/spinner.statusbar")
    pid, master = spawn([binary, "-c", config, "--", zsh, "-f", "-i"])
    data = b""
    try:
        os.write(master, b"stty -echo tostop\n")
        time.sleep(0.2)
        cmd = shlex.quote(os.path.abspath(binary)) + " push background -- sh -c 'sleep 0.1; printf finished' & wait; print -r -- __PUSH_DONE__:$?\n"
        os.write(master, cmd.encode())
        data = read_until(master, data, b"__PUSH_DONE__:0", timeout=5)
        assert b"suspended (tty output)" not in data, data[-1000:]
        # Programs such as ffmpeg change terminal settings through stdin even
        # when stdout/stderr are pipes. That also raises SIGTTOU in a background
        # process group, independently of TOSTOP.
        probe = (
            "import os, termios; "
            "tty = os.isatty(0); "
            "termios.tcsetattr(0, termios.TCSANOW, termios.tcgetattr(0)) if tty else None; "
            "assert not tty; assert os.read(0, 1) == b''; print('stdin detached')"
        )
        cmd = "stty -tostop; " + shlex.join([
            os.path.abspath(binary), "push", "terminal-input", "--", sys.executable, "-c", probe,
        ]) + " & wait $!; print -r -- __INPUT_DONE__:$?\n"
        os.write(master, cmd.encode())
        data = read_until(master, data, b"__INPUT_DONE__:0", timeout=5)
        assert b"suspended" not in data, data[-1000:]
        cmd = "printf payload | " + shlex.join([
            os.path.abspath(binary), "push", "piped-input", "--", sys.executable, "-c",
            "import sys; assert sys.stdin.read() == 'payload'; print('pipe preserved')",
        ]) + " & wait $!; print -r -- __PIPE_DONE__:$?\n"
        os.write(master, cmd.encode())
        data = read_until(master, data, b"__PIPE_DONE__:0", timeout=5)
        cmd = shlex.join([
            os.path.abspath(binary), "push", "foreground-input", "--", sys.executable, "-c",
            "import os; assert os.isatty(0); print('terminal preserved')",
        ]) + "; print -r -- __FOREGROUND_DONE__:$?\n"
        os.write(master, cmd.encode())
        data = read_until(master, data, b"__FOREGROUND_DONE__:0", timeout=5)
    finally:
        stop(pid, master)
    print("background push avoids terminal output and gives its command non-terminal stdin")


def check_hidden_push_without_paint(binary):
    config = ('[line.a]\ntext = A\n[line.b]\ntext = B\n'
              '[line.c]\ntext = C\n[push]\ntext = "#(value)"\n')
    child = CHILD_PRELUDE + r'''
mark('HIDDEN_READY')
assert run('push', input=b'hidden value') == '4'
mark('HIDDEN_ADDED')
run('pop', '4')
mark('HIDDEN_REMOVED')
'''
    code, data = run_session(binary, config, child, rows=5, raw=True)
    assert code == 0, data[-1000:]
    for start, end in ((b'HIDDEN_READY', b'HIDDEN_ADDED'),
                       (b'HIDDEN_ADDED', b'HIDDEN_REMOVED')):
        segment = between(data, start, end)
        assert PAINT_START not in segment, segment
        assert b'\x1b[2K' not in segment, segment
    print('hidden tail push/pop emit no bar paint or erase')


def check_list(binary):
    child = CHILD_PRELUDE + r"""
import concurrent.futures, json, socket

def listing(*args):
    value = json.loads(run('list', '--json', *args))
    assert set(value) == {'version', 'lines'} and value['version'] == 1, value
    return value['lines']

initial = listing()
assert [x['name'] for x in initial] == ['base', 'empty', 'hidden'], initial
assert [x['visible'] for x in initial] == [True, True, False], initial
assert all(x['value'] is None and x['fifo'] is None for x in initial), initial
assert listing('--pushed') == []
assert listing('--pushed', '--short') == []
assert run('list', '--pushed', '--short').split() == ['ID', 'NAME', 'STATUS', 'VALUE']
assert run('list', '--pushed').split() == ['ID', 'NAME', 'KIND', 'STATUS', 'VISIBLE', 'FIFO', 'VALUE']
run('set', 'empty', '')
value = '\x1b[31m"\\Καλημέρα\t界'
run('set', 'hidden', value, '--status', 'failed')
updated = listing()
assert updated[1]['value'] == ''
# set normalizes tabs to spaces; list returns the stored override.
assert updated[2]['value'] == value.replace('\t', ' '), updated[2]
assert updated[2]['status'] == 'failed' and not updated[2]['visible']
short_fields = ('id', 'name', 'status', 'value')
assert listing('--short') == [{key: x[key] for key in short_fields} for x in updated]
short_table = run('list', '--short')
assert short_table.splitlines()[0].split() == ['ID', 'NAME', 'STATUS', 'VALUE']
assert len(short_table.splitlines()) == 4 and '<default>' in short_table and '\x1b' not in short_table
assert '\\x1b[31m' in short_table and '""' in short_table
table = run('list')
assert '\x1b' not in table and '\\x1b[31m' in table and '<default>' in table
assert '""' in table and len(table.splitlines()) == 4, table
run('set', 'empty', '--reset')
assert listing()[1]['value'] is None
unnamed = run('push', input=b'unnamed')
run('push', 'job', input=b'finished')
pushed = listing('--pushed')
assert [x['id'] for x in pushed] == [int(unnamed), int(unnamed) + 1], pushed
assert [x['name'] for x in pushed] == [None, 'job'], pushed
assert all(x['kind'] == 'pushed' and x['status'] == 'done' and not x['visible'] for x in pushed)
# Bindings are discovered by stable line ID, including hidden and unnamed lines.
base_fifo = run('bind', 'base')
hidden_fifo = run('bind', 'hidden')
unnamed_fifo = run('bind', unnamed)
bound = listing()
assert [x['fifo'] for x in bound] == [base_fifo, None, hidden_fifo, unnamed_fifo, None], bound
assert base_fifo in run('list') and hidden_fifo in run('list')
assert listing('--pushed')[0]['fifo'] == unnamed_fifo
assert listing('--pushed', '--short') == [{key: x[key] for key in short_fields} for x in bound if x['kind'] == 'pushed']
short_pushed = run('list', '--short', '--pushed').splitlines()
assert short_pushed[0].split() == ['ID', 'NAME', 'STATUS', 'VALUE']
assert len(short_pushed) == 3 and all('.fifos/' not in row for row in short_pushed)
run('bind', '--unbind', unnamed)
assert listing('--pushed')[0]['fifo'] is None
# Reordering config lines preserves IDs and pushed rows; visibility follows layout.
run('config', input=b'[line.hidden]\ndefault = fallback\n[line.base]\n[line.empty]\n')
settle()
reordered = listing()
assert [x['id'] for x in reordered] == [initial[2]['id'], initial[0]['id'], initial[1]['id'], *[x['id'] for x in pushed]], reordered
assert reordered[0]['visible'] and not reordered[2]['visible']
assert reordered[0]['value'] == updated[2]['value']
assert [x['fifo'] for x in reordered[:3]] == [hidden_fifo, base_fifo, None]
run('bind', '--unbind', 'hidden')
assert listing()[0]['fifo'] is None
pushed_fifo = run('push', 'fifo-job', '--fifo')
assert listing('--pushed')[-1]['fifo'] == pushed_fifo
assert pushed_fifo in run('list', '--pushed')
run('pop', 'fifo-job')
assert all(x['fifo'] != pushed_fifo for x in listing())
# A snapshot must fit more than a datagram and preserve maximum-length values.
run('pop', '--all')
long_value = '界' * 341 + 'x'
for n in range(24):
    run('push', 'large-%d' % n, input=long_value.encode())
large = listing('--pushed')
assert len(large) == 24 and all(x['value'] == long_value for x in large), large
# Both filters share the atomic source snapshot and cannot affect other readers.
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    futures = [pool.submit(listing, *(['--pushed'] if n % 2 else [])) for n in range(16)]
    for n, future in enumerate(futures):
        entries = future.result()
        assert len(entries) == (24 if n % 2 else 27), len(entries)
        assert len({x['id'] for x in entries}) == len(entries)
snapshot_path = os.environ['STATUSBAR_STATE'] + '.lines'
assert stat.S_IMODE(os.stat(snapshot_path).st_mode) == 0o600
# Denied queries must not refresh the snapshot or return any data.
before = os.stat(snapshot_path).st_mtime_ns
wrong = os.environ.copy(); wrong['STATUSBAR_SESSION_ID'] = '0' * 32
run('list', '--json', env=wrong, code=1)
assert os.stat(snapshot_path).st_mtime_ns == before
outside = os.environ.copy(); outside.pop('STATUSBAR_SESSION_ID'); outside.pop('STATUSBAR_STATE')
run('list', '--json', env=outside, code=2)
stale = os.environ.copy(); stale['STATUSBAR_STATE'] += '-missing'
run('list', '--json', env=stale, code=1)
run('list', 'extra', code=2)
run('list', '--unknown', code=2)
run('pop', '--all')
assert listing('--pushed') == []
print('SNAPSHOT_PATH=' + snapshot_path, flush=True)
print('LIST_OK', flush=True)
"""
    config = '[line.base]\ndefault = fallback\n[line.empty]\n[line.hidden]\n'
    code, data = run_session(binary, config, child, rows=4, timeout=35)
    assert code == 0 and b'LIST_OK' in data, (code, data[-6000:])
    match = re.search(rb'SNAPSHOT_PATH=([^\r\n\x1b]+)', data)
    assert match is not None, data[-2000:]
    assert not os.path.exists(match[1].decode()), match[1]
    print('line listing, JSON, filtering, hidden rows, concurrent snapshots, and cleanup passed')


def check_push_pop(binary):
    child = CHILD_PRELUDE + r'''
from subprocess import PIPE, Popen
first = run('push', input=b'partial\rfirst final\n')
second = run('push', 'named', input='Καλημέρα ## #[bold]'.encode())
assert first == '2' and second == 'named', (first, second)
for args in (['5'], ['a.b'], ['1', 'x']):
    run('push', *args, input=b'x', code=2)
for taken in ('named', 'base'):
    run('push', taken, input=b'x', code=1)
assert os.get_terminal_size(0).lines == 21
print('PUSHED_TWO', flush=True)
run('config', input=b'[line.base]\ntext = reloaded\n[line.extra]\ntext = new\n[push]\ntext = "#[fg=#654321]> #[default]#(value)#(fill: )#[fg=#abcdef,bold]<#(name)>#[default]"\n')
settle()
run('pop', first)
run('pop', first, code=1)
run('pop', 'base', code=1)
print('POPPED_FIRST', flush=True)
# A removed producer can still finish, and its ID is never reused.
p = Popen([b, 'push'], stdin=PIPE, stdout=PIPE, stderr=PIPE)
p.stdin.write(b'in progress'); p.stdin.flush(); time.sleep(1)
run('pop', '5')
p.stdin.write(b'\rfinished'); p.stdin.close()
assert p.wait(timeout=4) == 0, p.stderr.read()
assert p.stdout.read() == b'5\n'
# A retired producer cannot touch a replacement with the same name.
p = Popen([b, 'push', 'job'], stdin=PIPE, stdout=PIPE, stderr=PIPE)
p.stdin.write(b'old job'); p.stdin.flush(); time.sleep(1)
run('pop', 'job')
assert run('push', 'job', input=b'new job\n') == 'job'
p.stdin.write(b'\rSTALE UPDATE'); p.stdin.close()
assert p.wait(timeout=4) == 0, p.stderr.read()
assert p.stdout.read() == b'job\n'
mark('REPLACED_JOB')
run('pop', 'job')
simultaneous = [Popen([b, 'push'], stdin=PIPE, stdout=PIPE, stderr=PIPE) for _ in range(2)]
for stream, value in zip(simultaneous, (b'left', b'right')):
    stream.stdin.write(value); stream.stdin.close()
ids = []
for stream in simultaneous:
    assert stream.wait(timeout=5) == 0, stream.stderr.read()
    ids.append(stream.stdout.read().strip())
assert set(ids) == {b'8', b'9'}, ids
for line_id in ids:
    run('pop', line_id.decode())
assert run('push', input=b'') == '10'
run('pop', '10')
command = subprocess.run([b, 'push', '--', sys.executable, '-c',
                          'import os,sys; '
                          'sys.stdout.write("started\\n"); sys.stdout.flush(); '
                          'w=int(os.environ["COLUMNS"]); '
                          'sys.stderr.write("#" * (w-6) + " 99.9%\\r"); '
                          'sys.exit(7 if w==74 else 9)'], capture_output=True)
assert command.returncode == 7, (command.returncode, command.stderr)
assert command.stdout == b'11\n', command.stdout
assert command.stderr == b'', command.stderr
settle()
run('pop', '11')
named = subprocess.run([b, 'push', 'download', '--', sys.executable, '-c', 'import os; print("width=" + os.environ["COLUMNS"])'], capture_output=True)
assert named.returncode == 0 and named.stdout == b'download\n', named
settle()
run('pop', 'download')
run('pop', 'named')
missing = subprocess.run([b, 'push', '--', '/nonexistent/command'], capture_output=True)
assert missing.returncode == 1 and b'cannot start command' in missing.stderr, missing
stack = [run('push', input=value) for value in (b'older', b'middle', b'newer')]
assert stack == ['14', '15', '16'], stack
run('pop', '15')
assert run('pop') == ''
run('pop', '14')
empty = subprocess.run([b, 'pop'], capture_output=True)
assert empty.returncode == 1 and b'no pushed lines' in empty.stderr, empty
wrong = os.environ.copy(); wrong['STATUSBAR_SESSION_ID'] = '0' * 32
assert subprocess.run([b, 'pop', 'named'], env=wrong, capture_output=True).returncode != 0
assert subprocess.run([b, 'push'], env=wrong, input=b'x', capture_output=True).returncode != 0
# A cursor save that is never restored must not starve line requests.
sys.stdout.write('\x1b7'); sys.stdout.flush()
assert run('push', input=b'saved cursor') == '17'
run('pop', '17')
p = Popen([b, 'push'], stdin=PIPE, stdout=PIPE, stderr=PIPE)
p.stdin.write(b'active before clear'); p.stdin.flush(); time.sleep(1)
assert run('push', input=b'completed before clear') == '19'
assert os.get_terminal_size(0).lines == 20
run('pop', '--all', '19', code=2)
assert subprocess.run([b, 'pop', '--all'], env=wrong, capture_output=True).returncode != 0
assert os.get_terminal_size(0).lines == 20
assert run('pop', '--all') == ''
assert os.get_terminal_size(0).lines == 22
assert run('pop', '-a') == ''
p.stdin.write(b'late output'); p.stdin.close()
assert p.wait(timeout=4) == 0, p.stderr.read()
assert p.stdout.read() == b'18\n'
assert run('push', input=b'new after clear') == '20'
assert run('pop', '-a') == ''
print('PUSH_POP_OK', flush=True)
'''
    config = '[line.base]\ntext = configured\n[push]\ntext = "#[fg=#123456]> #[default]#(value)#(fill: )#[fg=#abcdef,bold]<#(name)>#[default]"\n'
    code, data = run_session(binary, config, child, timeout=25)
    assert code == 0 and b'PUSH_POP_OK' in data, data[-2500:]
    rows = painted(data)
    assert any(row.startswith(b'> first final') and row.endswith(b'<2>') for row in rows), rows[-6:]
    assert any(row.startswith('> Καλημέρα ## #[bold]'.encode()) and row.endswith(b'<named>') for row in rows), rows[-6:]
    assert b'\x1b[0;38;2;18;52;86m' in data and b'38;2;171;205;239' in data, data[-2500:]
    assert b'\x1b[0;38;2;101;67;33m' in data, data[-2500:]
    assert b'reloaded' in plain(data) and b'in progress' in plain(data), data[-700:]
    assert any(row.startswith(b'> new job') for row in rows), rows
    assert b'STALE UPDATE' not in plain(data), data[-2000:]
    assert any(row.startswith(b'> width=68') and row.endswith(b'<download>') for row in rows), rows[-8:]
    assert any(b'99.9%' in row and row.endswith(b'<11>') for row in rows), rows[-8:]
    print('push/pop names, IDs, command width, reloads, retired producers, pop --all, and authentication passed')


def check_fifo(binary):
    child = CHILD_PRELUDE + r'''
directory = os.environ['STATUSBAR_FIFOS']
assert directory == os.environ['STATUSBAR_STATE'] + '.fifos'
assert 'STATUSBAR_SLOTS' not in os.environ
assert not os.path.exists(directory)
rows = os.get_terminal_size(0).lines
prompt = run('bind', 'prompt')
assert prompt == directory + '/prompt' and stat.S_ISFIFO(os.stat(prompt).st_mode)
assert os.stat(prompt).st_mode & 0o777 == 0o600
assert os.stat(directory).st_mode & 0o777 == 0o700
# Binding by ID or name reaches one pipe, named after the line.
assert run('bind', '2') == prompt and run('bind', 'prompt') == prompt
assert os.get_terminal_size(0).lines == rows
with open(prompt, 'wb') as writer:
    writer.write(b'one '); writer.flush(); writer.write(b'two\n')
settle()
run('set', 'prompt', 'manual')
settle()
with open(prompt, 'wb') as writer: writer.write(b'one two\n')
settle()
with open(prompt, 'wb') as writer: writer.write(b'\x1b[31mRED\x1b[0m\rBLUE\n')
settle()
with open(prompt, 'wb') as writer: writer.write(b'PARTIAL')
settle()
with open(prompt, 'wb') as writer: writer.write(b'\n#[bold]LITERAL #(value)\n')
mark('LITERAL_WRITTEN')
build = run('push', 'build', '--fifo')
assert build == directory + '/build' and stat.S_ISFIFO(os.stat(build).st_mode)
assert run('bind', 'build') == build and run('bind', '3') == build
assert os.get_terminal_size(0).lines == rows - 1
with open(build, 'wb') as writer: writer.write('Καλημέρα\n'.encode())
settle()
# Input written before a status change is applied first.
with open(build, 'wb') as writer: writer.write(b'FINAL')
run('set', 'build', '--status', 'success')
mark('BUILD_SUCCESS')
# A status is not a stream end: later input still updates the value.
with open(build, 'wb') as writer: writer.write(b'\nLATER\n')
mark('BUILD_LATER')
unnamed = run('push', '--fifo')
name = os.path.basename(unnamed)
assert name == '4' and unnamed == directory + '/4'
with open(unnamed, 'wb') as writer: writer.write(b'UNNAMED\n')
settle()
run('set', name, '--status', 'failed')
settle()
run('pop', name)
assert not os.path.exists(unnamed)
fd, nested_info = tempfile.mkstemp(); os.close(fd)
try:
    nested_code = ('import os,subprocess,sys; '
        'p=subprocess.run([sys.argv[2],"push","nested","--fifo"],capture_output=True,check=True).stdout.strip().decode(); '
        'open(sys.argv[1],"w").write(os.environ["STATUSBAR_FIFOS"]+"\\n"+p); '
        'open(p,"wb").write(b"NESTED\\n")')
    assert subprocess.run([b, '--', sys.executable, '-c', nested_code, nested_info, b], timeout=8).returncode == 0
    nested_dir, nested_path = open(nested_info).read().splitlines()
    assert nested_dir != directory and nested_path.startswith(nested_dir + '/')
    assert not os.path.exists(nested_path) and not os.path.exists(nested_dir)
    assert os.path.exists(build) and os.path.exists(prompt)
finally:
    os.unlink(nested_info)
# macOS does not wake poll for one large blocking FIFO write; the clock
# on the base line wakes the loop, which then drains the pipe.
flood = subprocess.Popen([sys.executable, '-c',
    'import sys; f=open(sys.argv[1],"wb"); f.write(b"flood\\n"*30000); f.close()', build])
run('set', 'base', 'RESPONSIVE')
assert flood.wait(timeout=10) == 0
# Surviving lines keep their pipes across reloads; failed reloads change nothing.
run('config', input=b'[line.base]\ntext = "CHANGED #(value)"\n[line.prompt]\ntext = "NEW[#(value)]"\n[push]\ntext = "#(value)#(fill: )#(status) [#(name)]"\n')
settle()
assert os.path.exists(prompt) and os.path.exists(build)
assert subprocess.run([b, 'config'], input=b'[bad]\n', capture_output=True).returncode != 0
assert os.path.exists(prompt) and os.path.exists(build)
# Unbinding keeps the line, its value and its status.
old_writer = os.open(prompt, os.O_WRONLY)
os.write(old_writer, b'BEFORE_UNBIND\n')
settle()
run('bind', '-u', 'prompt')
assert not os.path.exists(prompt)
try:
    os.write(old_writer, b'OLD\n')
    raise AssertionError('removed FIFO writer stayed connected')
except BrokenPipeError:
    pass
os.close(old_writer)
run('bind', '--unbind', '2')
mark('UNBOUND')
assert run('bind', 'prompt') == prompt
run('bind', '--unbind', 'build')
assert not os.path.exists(build)
assert run('bind', 'build') == build
for args, code in ((['missing'], 1), (['../escape'], 2), (['a.b'], 2), (['0'], 2), ([], 2)):
    run('bind', *args, code=code)
wrong = os.environ.copy(); wrong['STATUSBAR_SESSION_ID'] = '0' * 32
assert subprocess.run([b, 'bind', 'base'], env=wrong, capture_output=True).returncode != 0
assert not os.path.exists(directory + '/base')
outside = os.environ.copy(); outside.pop('STATUSBAR_SESSION_ID'); outside.pop('STATUSBAR_STATE')
assert subprocess.run([b, 'bind', 'base'], env=outside, capture_output=True).returncode == 2
run('pop', '--all')
assert not os.path.exists(build) and os.path.exists(prompt)
# Removing a configured line in a reload removes its pipe.
run('config', input=b'[line.base]\ntext = SHRUNK\n')
deadline = time.monotonic() + 2
while os.path.exists(prompt) and time.monotonic() < deadline: time.sleep(.02)
assert not os.path.exists(prompt)
with open(directory + '/collision', 'wb') as file: file.write(b'keep')
rows = os.get_terminal_size(0).lines
run('push', 'collision', '--fifo', code=1)
assert open(directory + '/collision', 'rb').read() == b'keep'
assert os.get_terminal_size(0).lines == rows
run('set', 'collision', 'x', code=1)
os.unlink(directory + '/collision')
end = run('push', 'end', '--fifo')
print('FIFO_CLEANUP=' + end, flush=True)
print('FIFO_OK', flush=True)
'''
    config = ('[line.base]\ntext = "BASE #(value)#(fill: )#(datetime:%S)"\n[line.prompt]\ndefault = SLOTBASE\ntext = "PROMPT[#(value)]"\n'
              '[push]\ntext = "#(value)#(fill: )#(status) [#(name)]"\n')
    code, data = run_session(binary, config, child, timeout=20)
    assert code == 0 and b'FIFO_OK' in data, data[-2500:]
    text = plain(data)
    assert b'PROMPT[SLOTBASE]' in text and b'PROMPT[one two]' in text and b'PROMPT[manual]' in text, text[-2500:]
    assert text.find(b'PROMPT[one two]', text.find(b'PROMPT[manual]')) > text.find(b'PROMPT[manual]'), text[-2500:]
    assert b'PROMPT[BLUE]' in text and b'PROMPT[PARTIAL]' in text, text[-2500:]
    assert b'PROMPT[#[bold]LITERAL #(value)]' in text, text[-2500:]
    rows = painted(data)
    assert any('Καλημέρα'.encode() in row and row.endswith(b'running [build]') for row in rows), rows[-10:]
    assert any(row.startswith(b'FINAL') and row.endswith(b'success [build]') for row in rows), rows[-10:]
    assert any(row.startswith(b'LATER') and row.endswith(b'success [build]') for row in rows), rows[-10:]
    assert any(row.startswith(b'UNNAMED') and row.endswith(b'failed [4]') for row in rows), rows[-10:]
    assert b'BASE RESPONSIVE' in text and b'NEW[BEFORE_UNBIND]' in text, text[-2500:]
    assert b'NEW[OLD]' not in text, text[-2500:]
    cleanup = re.search(rb'FIFO_CLEANUP=([^\r\n]+)', data)
    assert cleanup and not os.path.exists(cleanup.group(1).decode()), data[-2500:]
    assert not os.path.exists(os.path.dirname(cleanup.group(1).decode())), data[-2500:]
    print('bind, push --fifo, ID/name equivalence, input order, unbind, reload pruning, and cleanup passed')


def check_fifo_signal_cleanup(binary):
    child = r'''
import os, subprocess, sys, time
path = subprocess.run([sys.argv[1], 'push', 'signal', '--fifo'], capture_output=True, check=True).stdout.strip().decode()
print('SIGNAL_FIFO=' + path, flush=True)
time.sleep(30)
'''
    pid, master = spawn([binary, '--', sys.executable, '-c', child, binary], env=clean_env())
    reaped = False
    try:
        data = read_until(master, b'', b'SIGNAL_FIFO=', timeout=5)
        data = read_until(master, data, b'\r\n', timeout=5)
        path = re.search(rb'SIGNAL_FIFO=([^\r\n]+)', data)
        assert path and os.path.exists(path.group(1).decode()), data[-500:]
        os.kill(pid, signal.SIGTERM)
        reap_while_draining(pid, master, timeout=5)
        reaped = True
        assert not os.path.exists(path.group(1).decode())
        assert not os.path.exists(os.path.dirname(path.group(1).decode()))
    finally:
        if not reaped:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
            reap_while_draining(pid, master, timeout=5)
        os.close(master)
    print('named FIFO signal cleanup passed')


def check_push_completion(binary):
    child = CHILD_PRELUDE + r'''
def pop():
    subprocess.run([b, 'pop'], check=True, capture_output=True)
p = subprocess.Popen([b, 'push'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
p.stdin.write(b'PIPE_CONTENT'); p.stdin.flush(); time.sleep(1)
p.stdin.close()
assert p.wait(timeout=4) == 0
settle(); pop()
for code in (0, 7, 130):
    command = subprocess.run([b, 'push', '--', sys.executable, '-c',
                              f'print("COMMAND_{code}"); raise SystemExit({code})'], capture_output=True)
    assert command.returncode == code, command
    settle(); pop()
command = subprocess.run([b, 'push', '--', sys.executable, '-c',
                          'import os,signal; print("SIGNALED", flush=True); os.kill(os.getpid(), signal.SIGTERM)'], capture_output=True)
assert command.returncode == 128 + signal.SIGTERM, command
settle()
# Reload renders the stored status with the new templates.
subprocess.run([b, 'config'], input=b'[line.a]\n[push]\ntext = RUNNING_AGAIN #(value)\nfailed = RELOADED_#(status)_#(value)\n', check=True, capture_output=True)
settle()
# Any transition is allowed, keeping the value.
run('set', '6', '--status', 'running'); settle()
run('set', '6', '--status', 'normal'); settle()
pop()
print('COMPLETION_OK', flush=True)
'''
    config = '''[line.a]
text = configured
[push]
text = "ACTIVE #(value)"
done = "PIPE_DONE #(value)"
success = "COMMAND_OK #(value)"
failed = "COMMAND_FAILED #(value)"
'''
    code, data = run_session(binary, config, child, timeout=15)
    assert code == 0 and b'COMPLETION_OK' in data, data[-3000:]
    text = plain(data)
    assert text.index(b'ACTIVE PIPE_CONTENT') < text.index(b'PIPE_DONE PIPE_CONTENT'), text[-1000:]
    for expected in (b'COMMAND_OK COMMAND_0', b'COMMAND_FAILED COMMAND_7', b'COMMAND_FAILED COMMAND_130',
                     b'COMMAND_FAILED SIGNALED', b'RELOADED_failed_SIGNALED', b'RUNNING_AGAIN SIGNALED'):
        assert expected in text, (expected, text[-4000:])
    print('push completion statuses, exit codes, signals, transitions, and reload passed')


def check_push_initial_status(binary):
    child = CHILD_PRELUDE + r'''
assert os.isatty(0)
assert run('push', 'bare') == 'bare'
settle()
run('pop', 'bare')
assert run('push', 'manual', '--status', 'normal') == 'manual'
settle()
run('set', 'manual', 'UPDATED', '--status', 'success'); settle()
run('pop', 'manual')
unnamed = run('push', '--status', 'done')
assert unnamed.isdecimal(), unnamed
run('pop', unnamed)
run('push', 'invalid', '--status', 'bad', code=2)
path = run('push', 'fifo', '--fifo', '--status', 'failed')
assert stat.S_ISFIFO(os.stat(path).st_mode)
with open(path, 'w') as output:
    output.write('FIFO_VALUE\n')
settle()
run('pop', 'fifo')
p = subprocess.Popen([b, 'push', 'pipe', '--status', 'failed'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
p.stdin.write(b'PIPE_VALUE\n'); p.stdin.flush(); time.sleep(1)
p.stdin.close()
assert p.wait(timeout=4) == 0
settle(); run('pop', 'pipe')
with tempfile.TemporaryFile() as source:
    source.write(b'FILE_VALUE\n'); source.seek(0)
    subprocess.run([b, 'push', 'file', '--status', 'failed'], stdin=source, capture_output=True, check=True)
settle(); run('pop', 'file')
run('push', 'command', '--status', 'failed', '--', sys.executable, '-c',
    'import os,time; assert os.environ["COLUMNS"] == "73"; print("COMMAND_VALUE", flush=True); time.sleep(.3)')
settle(); run('pop', 'command')
print('INITIAL_STATUS_OK', flush=True)
'''
    config = '''[line.base]
text = configured
[push]
text = "#(name):#(status):#(value)"
failed = "FAILED #(value)"
'''
    code, data = run_session(binary, config, child)
    assert code == 0 and b'INITIAL_STATUS_OK' in data, data[-4000:]
    text = plain(data)
    for expected in (b'bare:running:', b'manual:normal:', b'manual:success:UPDATED', b'FAILED FIFO_VALUE',
                     b'FAILED PIPE_VALUE', b'pipe:done:PIPE_VALUE', b'file:done:FILE_VALUE',
                     b'FAILED COMMAND_VALUE', b'command:success:COMMAND_VALUE'):
        assert expected in text, (expected, text[-4000:])
    print('bare push and initial statuses for terminal, pipe, file, FIFO, and command passed')


def check_push_spinner(binary):
    child = r'''
import os, subprocess, sys, time
b = sys.argv[1]
r = subprocess.run([b, 'push', '--', sys.executable, '-c',
    'import os,time; print("width=" + os.environ["COLUMNS"], flush=True); time.sleep(.8)'], capture_output=True)
assert r.returncode == 0 and r.stdout == b'2\n', r
# A completed line must remain quiet even while the session stays open.
time.sleep(.4)
with open(os.environ['SPINNER_COUNTER']) as f:
    assert f.read().splitlines() == ['once']
print('SPINNER_OK', flush=True)
'''
    config = '''[line.a]
text = #(command:note)
[push]
spinner = "-界"
spinner_interval = 0.1
text = "<#(spinner)>#(value)#(fill: )[#(name)]"
done = "DONE #(spinner)#(value)"
success = "DONE #(spinner)#(value)"
[command.note]
run = printf 'once\\n' >> "$SPINNER_COUNTER"; printf snapshot
interval = 86400
'''
    with tempfile.TemporaryDirectory() as directory:
        env = os.environ.copy()
        env['SPINNER_COUNTER'] = os.path.join(directory, 'counter')
        code, data = run_session(binary, config, child, env=env, timeout=8)
        assert code == 0 and b'SPINNER_OK' in data, data[-2000:]
        text = plain(data)
        assert text.count(b'<- >width=73') >= 2, text[-2000:]
        assert text.count('<界>width=73'.encode()) >= 2, text[-2000:]
        assert b'DONE width=73' in text, text[-2000:]
        completed = text[text.index(b'DONE width=73'):]
        assert b'<- >' not in completed and '<界>'.encode() not in completed, completed
    print('push spinner animation, stable command width, completion, and command pacing passed')


def check_reload_lines(binary):
    child = CHILD_PRELUDE + r'''
run('set', 'a', 'kept', '--status', 'success')
run('set', 'b', '')
c = run('bind', 'c')
mark('BEFORE_RELOAD')
run('config', input=b'[line.c]\ntext = "C[#(value)]"\n[line.b]\ndefault = B1\ntext = "B[#(value)]"\n[line.a]\ndefault = A1\ntext = "A[#(value)|#(status)]"\n[line.d]\ntext = "D[#(value)]"\n')
mark('REORDERED')
assert os.path.exists(c)
# IDs survive reordering: a is still ID 1, and d is new.
run('set', '1', 'by-id'); run('set', '4', 'new-line')
mark('BY_ID')
run('set', 'a', '--reset')
run('config', input=b'[line.a]\ndefault = A2\ntext = "A[#(value)|#(status)]"\n[line.b]\ntext = "B[#(value)]"\n')
mark('DROPPED')
deadline = time.monotonic() + 2
while os.path.exists(c) and time.monotonic() < deadline: time.sleep(.02)
assert not os.path.exists(c)
run('set', 'c', 'x', code=1)
# A configured name used by a pushed line, or a bad config, changes nothing.
assert run('push', 'job', input=b'pushed\n') == 'job'
run('config', input=b'[line.a]\n[line.job]\n')
run('config', input=b'[line.a]\ntext = #(nope)\n', code=2)
mark('REJECTED')
run('set', 'a', 'still')
mark('RELOAD_OK')
'''
    config = '[line.a]\ndefault = A0\ntext = "A[#(value)|#(status)]"\n[line.b]\ndefault = B0\ntext = "B[#(value)]"\n[line.c]\ntext = "C[#(value)]"\n'
    code, data = run_session(binary, config, child, timeout=15)
    assert code == 0 and b'RELOAD_OK' in data, data[-3000:]
    text = plain(data)
    before = between(text, b'BEFORE_RELOAD', b'REORDERED')
    assert b'A[kept|success]' in before and b'B[]' in before, before
    by_id = between(text, b'REORDERED', b'BY_ID')
    assert b'A[by-id|success]' in by_id and b'D[new-line]' in by_id, by_id
    dropped = between(text, b'BY_ID', b'DROPPED')
    assert b'A[A2|success]' in dropped and b'B[]' in dropped, dropped
    rejected = between(text, b'DROPPED', b'RELOAD_OK')
    assert b'A[still|success]' in rejected and b'pushed' in rejected, rejected
    # Declaration order decides the rows: c, b, a, d from the top.
    rows = painted_rows(between(data, b'BEFORE_RELOAD', b'BY_ID'))
    tops = {row: texts[-1] for row, texts in rows.items()}
    assert tops[21].startswith(b'C[') and tops[22].startswith(b'B[') and tops[23].startswith(b'A[') and tops[24].startswith(b'D['), tops
    print('reload keeps line state by name, follows declaration order, prunes bindings, and rolls back')


def check_startup_recovery(binary):
    """A config that cannot be used never keeps the shell from starting."""
    child = "test -t 0 && printf CHILD_STARTED; exit 5"
    with tempfile.TemporaryDirectory() as folder:
        invalid = os.path.join(folder, "bad config.statusbar")
        with open(invalid, "w") as file:
            file.write("[line.a]\ntext = fine\n[line.b]\nleft = old syntax\n")
        valid = os.path.join(folder, "valid.config")
        with open(valid, "w") as file:
            file.write("[line.a]\ntext = VALID_ANY_SUFFIX\n")
        cases = [
            ([binary, "--config", invalid], {}, b"statusbar: line 4: left, right and rule were removed"),
            ([binary], {"STATUSBAR_CONFIG": invalid}, b"statusbar: line 4:"),
            ([binary, "--config", os.path.join(folder, "missing.statusbar")], {}, b"statusbar: cannot read config: FileNotFound"),
            ([binary, "--config", folder], {}, b"statusbar: cannot read config:"),
        ]
        for argv, extra, message in cases:
            env = clean_env()
            env.update(extra)
            env["XDG_CONFIG_HOME"] = os.path.join(folder, "empty-xdg")
            code, data = capture_pty([*argv, "--", "/bin/sh", "-c", child], env=env)
            assert code == 5 and b"CHILD_STARTED" in data, (argv, data[-1500:])
            assert any(message in row for row in painted(data)), (message, painted(data))
        with open(invalid) as file:
            assert "left = old syntax" in file.read()
        # An explicit path works whatever its suffix.
        code, data = capture_pty([binary, "--config", valid, "--", "/bin/sh", "-c", child], env=clean_env())
        assert code == 5 and b"VALID_ANY_SUFFIX" in plain(data), data[-1500:]

        # Default discovery: the new file wins; an old file alone warns; no
        # file at all is an ordinary built-in start.
        xdg = os.path.join(folder, "xdg")
        directory = os.path.join(xdg, "statusbar")
        os.makedirs(directory)
        env = clean_env()
        env["XDG_CONFIG_HOME"] = xdg
        code, data = capture_pty([binary, "--", "/bin/sh", "-c", child], env=env)
        assert code == 5 and not any(b"statusbar:" in row for row in painted(data)), painted(data)
        assert subprocess.run([binary, "config", "--path"], env=env, capture_output=True).stdout == b"built-in\n"
        legacy = os.path.join(directory, "config")
        with open(legacy, "w") as file:
            file.write("[line.1]\nleft = LEGACY\n")
        code, data = capture_pty([binary, "--", "/bin/sh", "-c", child], env=env)
        assert code == 5 and b"LEGACY" not in plain(data), data[-1500:]
        assert any(b"the old config file is no longer loaded" in row for row in painted(data)), painted(data)
        current = os.path.join(directory, "config.statusbar")
        with open(current, "w") as file:
            file.write("[line.a]\ntext = NEW_DEFAULT\n")
        code, data = capture_pty([binary, "--", "/bin/sh", "-c", child], env=env)
        assert code == 5 and b"NEW_DEFAULT" in plain(data), data[-1500:]
        assert not any(b"old config" in row for row in painted(data)), painted(data)
        result = subprocess.run([binary, "config", "--path"], env=env, capture_output=True)
        assert result.stdout == os.fsencode(current) + b"\n", result

        # A valid replacement removes the warning; an invalid one keeps it.
        session = CHILD_PRELUDE + r'''
rows = os.get_terminal_size(0).lines
assert subprocess.run([b, 'config'], input=b'[bad]\n', capture_output=True).returncode == 2
run('config', input=b'[line.a]\ntext = #(unknown)\n', code=2)
mark('STILL_WARNED')
assert os.get_terminal_size(0).lines == rows
run('config', input=b'[line.a]\ntext = RECOVERED\n')
settle()
assert os.get_terminal_size(0).lines == rows + 2
mark('RECOVERED_OK')
'''
        env = clean_env()
        env["XDG_CONFIG_HOME"] = os.path.join(folder, "empty-xdg")
        code, data = capture_pty([binary, "--config", invalid, "--", sys.executable, "-c", session, binary], env=env, timeout=10)
        assert code == 0 and b"RECOVERED_OK" in data, data[-2000:]
        after = painted_rows(data[data.index(b"STILL_WARNED"):])
        assert any(b"RECOVERED" in text for texts in after.values() for text in texts), after
        final = painted_rows(data[data.index(b"STILL_WARNED"):])
        assert not any(b"statusbar: line" in texts[-1] for texts in final.values()), final
    print("startup recovery: invalid, missing and legacy configs start the shell with a warning; reload clears it")


def check_default_templates(binary):
    config = '''[line.prompt]
default = "#[fg=red]#(command:user)@"
default .= "#(command:host)#[default]"
text = "PROMPT[#(value)]"
[command.user]
run = printf alice
[command.host]
run = printf machine
'''
    child = CHILD_PRELUDE + r'''
mark('DEFAULT_START')
run('set', 'prompt', '#(command:user) #[bold]')
mark('DEFAULT_LITERAL')
run('set', 'prompt', '--reset')
mark('DEFAULT_RESET')
fifo = run('bind', 'prompt')
with open(fifo, 'w') as f: f.write('#[bold]FIFO\n')
mark('DEFAULT_FIFO')
run('set', 'prompt', '')
mark('DEFAULT_EMPTY')
layout = '[line.prompt]\ndefault = "NEW #(name) #(status)"\ntext = "PROMPT[#(value)]"\n'
run('config', input=layout.encode())
mark('DEFAULT_RELOADED_EMPTY')
run('set', 'prompt', '--reset', '--status', 'success')
mark('DEFAULT_RELOADED_RESET')
run('config', input=layout.replace('NEW ', 'LATEST ').encode())
mark('DEFAULT_RELOADED_LIVE')
run('set', 'prompt', 'kept')
run('config', input=layout.encode())
mark('DEFAULT_RELOADED_OVERRIDE')
run('set', 'prompt', '--reset')
mark('DEFAULT_OK')
'''
    code, data = run_session(binary, config, child)
    assert code == 0 and b'DEFAULT_OK' in data, data[-3000:]
    text = plain(data)
    assert b'PROMPT[alice@machine]' in text[:text.index(b'DEFAULT_START')], text
    for start, end, expected in (
        (b'DEFAULT_START', b'DEFAULT_LITERAL', b'PROMPT[#(command:user) #[bold]]'),
        (b'DEFAULT_LITERAL', b'DEFAULT_RESET', b'PROMPT[alice@machine]'),
        (b'DEFAULT_RESET', b'DEFAULT_FIFO', b'PROMPT[#[bold]FIFO]'),
        (b'DEFAULT_FIFO', b'DEFAULT_EMPTY', b'PROMPT[]'),
        (b'DEFAULT_EMPTY', b'DEFAULT_RELOADED_EMPTY', b'PROMPT[]'),
        (b'DEFAULT_RELOADED_EMPTY', b'DEFAULT_RELOADED_RESET', b'PROMPT[NEW prompt success]'),
        (b'DEFAULT_RELOADED_RESET', b'DEFAULT_RELOADED_LIVE', b'PROMPT[LATEST prompt success]'),
        (b'DEFAULT_RELOADED_LIVE', b'DEFAULT_RELOADED_OVERRIDE', b'PROMPT[kept]'),
        (b'DEFAULT_RELOADED_OVERRIDE', b'DEFAULT_OK', b'PROMPT[NEW prompt success]'),
    ):
        segment = between(text, start, end)
        assert expected in segment, (expected, segment)
    print('default templates expand, reset, reload, and preserve literal set/FIFO values')


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: multirow_pty.py STATUSBAR")
    binary = os.path.abspath(sys.argv[1])
    check_config_file(binary)
    check_set(binary)
    check_default_templates(binary)
    check_init_invocation(binary)
    check_stdin_config(binary)
    check_startup_recovery(binary)
    check_osc7_titles(binary)
    check_zsh(binary)
    check_fish(binary)
    check_nu(binary)
    check_init_features(binary)
    check_tracking(binary)
    check_tracking(binary, colors=True)
    check_geometry_results_do_not_highlight(binary)
    check_resize_command_runs(binary)
    check_datetime_and_terminal_properties(binary)
    check_adaptive_palette(binary)
    check_logging(binary)
    check_config_snapshots(binary)
    check_osc_config(binary)
    check_theme_growth(binary)
    check_background_job_exit(binary)
    check_background_push_tty_output(binary)
    check_hidden_push_without_paint(binary)
    check_push_pop(binary)
    check_list(binary)
    check_fifo(binary)
    check_fifo_signal_cleanup(binary)
    check_push_completion(binary)
    check_push_initial_status(binary)
    check_push_spinner(binary)
    check_reload_lines(binary)
    config = """\
[line.one]
text = "one#(fill:-)"
[line.two]
default = two
[line.three]
default = three
text = "#(value)#(fill: )configured-six"
"""
    script = r'''
statusbar_bin=$1
trap 'size=$(stty size); rows=${size%% *}; printf "__SIZE__:%s\n" "$rows"' WINCH
size=$(stty size); rows=${size%% *}; printf "__START__:%s:%s\n" "$rows" "${STATUSBAR_LINES-unset}"
while :; do
  IFS= read -r command || continue
  case "$command" in
    SET) "$statusbar_bin" set three hidden-value; printf '__SET__\n' ;;
    ROW) "$statusbar_bin" set two changed-row-two ;;
    CLEAR) printf '\033[2J__CLEAR__\n' ;;
    ALT) printf '\033[?1049h__ALT__\n' ;;
    NORMAL) printf '\033[?1049l__NORMAL__\n' ;;
    BYTES) printf '\033[32m__FORWARDED__\033[0m\n' ;;
    BAD) "$statusbar_bin" set missing bad 2>/dev/null; printf '__BAD__:%s\n' "$?" ;;
    EXIT) exit 0 ;;
  esac
done
'''
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".statusbar") as cfg:
        cfg.write(config)
        config_path = cfg.name
    pid = master = None
    try:
        argv = [binary, "-c", config_path, "--", "/bin/sh", "-c", script, "sh", binary]
        pid, master = spawn(argv, env=clean_env())
        data = read_until(master, b"", b"__START__:21:unset")
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
        data = read_until(master, data, b"__SIZE__:2")
        before_set = len(data)
        os.write(master, b"SET\n")
        data = read_until(master, data, b"__SET__")
        assert b"hidden-value" not in data[before_set:], "hidden row was painted at height 4"

        resize(master, 24)
        data = read_until(master, data, b"__SIZE__:21")
        data = read_until(master, data, b"hidden-value")

        os.write(master, b"BAD\n")
        data = read_until(master, data, b"__BAD__:1")

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

    print("multirow PTY checks passed")


if __name__ == "__main__":
    main()
