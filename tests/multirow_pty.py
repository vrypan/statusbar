#!/usr/bin/env python3
"""Deterministic PTY checks for configured rows, resizing, and slot updates."""

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
import urllib.parse


def resize(fd, rows, cols=80):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def session_state_stub(directory, lines):
    """Give shell integration tests a current row count without a full proxy."""
    path = os.path.join(directory, f"statusbar-state-{lines}")
    with open(path, "w", encoding="ascii") as state:
        state.write(f"statusbar-state 2\nlines {lines}\n")
    return path


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
                if not os.read(fd, 65536):
                    time.sleep(min(0.01, remaining))
            except OSError:
                time.sleep(min(0.01, remaining))


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
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        reap_while_draining(pid, master)
    finally:
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


def check_set_dash(binary):
    env = os.environ.copy()
    env.pop("STATUSBAR_STATE", None)
    env["STATUSBAR_LINES"] = "2"
    for args, value in ((["4", "-"], b"-"),
                        (["4", "--", "-"], b"-"),
                        (["--", "4", "-"], b"-"),
                        (["4", "-", "extra"], b"- extra")):
        code, data = capture_pty([binary, "set", *args], env)
        assert code == 0 and osc_value(data, 4) == value, data

    command = f"printf 'ignored' | {shlex.quote(binary)} set 4 -"
    code, data = capture_pty(["/bin/sh", "-c", command], env)
    assert code == 0 and osc_value(data, 4) == b"-", data
    print("set treats a sole dash as literal text")
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
        assert f"command '{stable}' set".encode() in absolute.stdout
        assert f"command '{binary}' set".encode() not in absolute.stdout

        path_env = env.copy()
        path_env["PATH"] = directory + os.pathsep + path_env.get("PATH", "")
        by_name = subprocess.run(
            ["statusbar", "init", "zsh"], env=path_env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        )
        assert b"command 'statusbar' set" in by_name.stdout

    lines_only = env.copy()
    lines_only.pop("STATUSBAR_STATE")
    lines_only["STATUSBAR_LINES"] = "2"
    outside = subprocess.run([binary, "init", "zsh"], env=lines_only,
                             capture_output=True, check=True)
    assert outside.stdout == b"", outside

    print("shell init preserves upgrade-safe invocation paths")


def check_stdin_config(binary):
    config = "interval = 0.1\nstyle = fg=blue\n[line.1]\nleft = PIPE_ONE\n[line.2]\nleft = #(printf PIPE_TWO)\n"
    q = shlex.quote
    child = r'''printf '__READY__:%s:%s\n' "$(stty size)" "$STATUSBAR_LINES"
while IFS= read -r value; do
    case "$value" in
        SIZE) printf '__SIZE__:%s\n' "$(stty size)" ;;
        RELOAD) printf '[line.1]\nleft = RELOADED\n' | "$1" config ;;
        EXIT) exit 7 ;;
        *) printf '__INPUT__:%s\n' "$value" ;;
    esac
done
'''
    command = shlex.join([binary, "--config=-", "--", "/bin/sh", "-c", child, "sh", binary])
    env = os.environ.copy()
    env["STATUSBAR_CONFIG"] = "/does/not/exist/statusbar-config"
    script = f"printf %s {q(config)} | {command}"
    pid, master = spawn(["/bin/sh", "-c", script], env=env)
    reaped = False
    try:
        data = read_until(master, b"", b"__READY__:22 80:2")
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
    code, data = capture_pty(["/bin/sh", "-c", script])
    assert code == 0 and b"HEREDOC_OK" in data, data

    # Validate before entering raw mode, launching the child, or querying the terminal.
    for text, message in [
        ("", b"stdin contains no config"),
        ("# no rows\n", b"config needs at least a [line.1] section"),
        ("[line.1]\nunknown = value\n", b"stdin:2:"),
    ]:
        script = f"printf %s {q(text)} | " + shlex.join([binary, "--config", "-", "--", "/bin/sh", "-c", "printf CHILD_STARTED"])
        code, data = capture_pty(["/bin/sh", "-c", script])
        assert code == 2 and message in data, data
        assert b"CHILD_STARTED" not in data and b"\x1b[" not in data, data

    for text, message in [
        (b"[line.1]\n#" + b"x" * 65536, b"limit 65536 bytes"),
        (config.encode(), b"cannot open /dev/tty for keyboard input"),
    ]:
        result = subprocess.run([binary, "--config", "-"], input=text, capture_output=True, start_new_session=True, timeout=5)
        assert result.returncode != 0 and message in result.stderr, result

    # --config - does not make redirected stdout an interactive terminal.
    with tempfile.TemporaryDirectory() as folder:
        output = os.path.join(folder, "output")
        script = f"printf %s {q(config)} | {q(binary)} --config - > {q(output)}"
        code, data = capture_pty(["/bin/sh", "-c", script])
        assert code == 1 and b"stdin and stdout must be a terminal" in data, data
        assert os.path.getsize(output) == 0

    for flag in ["--exec", "--lines", "--interval", "--style", "-e", "-n", "-i", "-s"]:
        result = subprocess.run([binary, flag, "1"], capture_output=True, timeout=5)
        assert result.returncode == 2, (flag, result)
    print("stdin configs, keyboard input, resize, reload, and terminal restoration passed")


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

    script = "printf '[line.1]\\nleft = bar\\n' | " + shlex.join([
        binary, "--config", "-",
        "--", "/bin/sh", "-c", 'printf %s "$1"', "sh", payload.decode("ascii"),
    ])
    argv = ["/bin/sh", "-c", script]
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
    env["STATUSBAR_STATE"] = "/statusbar-session-indicator"
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
    assert zero.returncode == 0
    assert b"__statusbar_report_cwd" in zero.stdout

    with tempfile.TemporaryDirectory() as directory:
        starship = os.path.join(directory, "starship")
        with open(starship, "w", encoding="utf-8") as file:
            file.write("#!/bin/sh\ncase $STARSHIP_TEST_MODE in\n  multi) printf 'bar%%%%literal\\nprompt' ;;\n  one) printf 'one%%%%literal' ;;\nesac\n")
        os.chmod(starship, 0o755)
        zenv = env.copy()
        zenv["STATUSBAR_STATE"] = session_state_stub(directory, 3)
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
        one_row_env["STATUSBAR_STATE"] = session_state_stub(directory, 1)
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
    env["STATUSBAR_STATE"] = "/statusbar-session-indicator"
    quoted_binary = shlex.quote(binary)
    with tempfile.TemporaryDirectory() as directory:
        starship = os.path.join(directory, "starship")
        with open(starship, "w", encoding="utf-8") as file:
            file.write("#!/bin/sh\ncase $STARSHIP_TEST_MODE in\n  multi) printf 'bar%%literal\\nprompt' ;;\n  one) printf 'one%%literal' ;;\nesac\n")
        os.chmod(starship, 0o755)
        fenv = env.copy()
        fenv["STATUSBAR_STATE"] = session_state_stub(directory, 3)
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
        one_row_env["STATUSBAR_STATE"] = session_state_stub(directory, 1)
        script = (
            f"set -gx STARSHIP_TEST_MODE multi; {quoted_binary} init fish | source; "
            "fish_prompt"
        )
        code, data = capture_pty([fish, "-N", "-c", script], one_row_env)
        assert code == 0, data
        assert b"SetUserVar=StatusBarSlot" not in data
        assert b"bar%literal\r\nprompt" in data, data

    print("fish integration passed")


def check_nu(binary):
    nu = shutil.which("nu")
    if nu is None:
        print("Nushell integration skipped: nu unavailable")
        return

    env = os.environ.copy()
    env["STATUSBAR_LINES"] = "3"
    env["STATUSBAR_STATE"] = "/statusbar-session-indicator"
    with tempfile.TemporaryDirectory() as directory:
        os.symlink(binary, os.path.join(directory, "statusbar"))
        starship = os.path.join(directory, "starship")
        with open(starship, "w", encoding="utf-8") as file:
            file.write("#!/bin/sh\ncase $STARSHIP_TEST_MODE in\n  multi) printf 'bar%%literal\\nprompt' ;;\n  one) printf 'one%%literal' ;;\nesac\n")
        os.chmod(starship, 0o755)
        nenv = env.copy()
        nenv["STATUSBAR_STATE"] = session_state_stub(directory, 3)
        nenv["PATH"] = directory + os.pathsep + nenv.get("PATH", "")

        sample = os.path.join(os.path.dirname(__file__), "..", "samples", "statusbar.nu")
        with open(sample, "rb") as file:
            integration = file.read()
        for slot in (3, 5):
            script_path = os.path.join(directory, "statusbar.nu")
            with open(script_path, "wb") as file:
                file.write(integration.replace(b"set 3 --", f"set {slot} --".encode()))
            nenv["STARSHIP_TEST_MODE"] = "multi"
            script = (
                '$env.CMD_DURATION_MS = "0823"; $env.LAST_EXIT_CODE = 0; '
                f'source {script_path}; let prompt = (do $env.PROMPT_COMMAND); print $prompt'
            )
            code, data = capture_pty([nu, "-n", "-c", script], nenv)
            assert code == 0, data
            assert osc_value(data, slot) == b"bar%literal", data
            assert b"prompt" in data, data

        nenv["STARSHIP_TEST_MODE"] = "one"
        code, data = capture_pty([nu, "-n", "-c", script], nenv)
        assert code == 0 and b"SetUserVar=StatusBarSlot" not in data, data
        assert b"one%literal" in data, data

        nenv["STARSHIP_TEST_MODE"] = "multi"
        one_row_env = nenv.copy()
        one_row_env["STATUSBAR_LINES"] = "1"
        one_row_env["STATUSBAR_STATE"] = session_state_stub(directory, 1)
        code, data = capture_pty([nu, "-n", "-c", script], one_row_env)
        assert code == 0 and b"SetUserVar=StatusBarSlot" not in data, data
        assert b"bar%literal\r\nprompt" in data, data

        target = os.path.join(directory, "space % café")
        os.mkdir(target)
        cwd_script = (
            f'source {script_path}; source {script_path}; cd "{target}"; '
            'print ($env.config.hooks.pre_prompt | length); '
            'do ($env.config.hooks.pre_prompt | last)'
        )
        code, data = capture_pty([nu, "-n", "-c", cwd_script], nenv)
        assert code == 0 and b"1\r\n" in data, data
        report = re.search(rb"\x1b\]7;file://(/.*?)\x07", data)
        assert report is not None, data
        assert urllib.parse.unquote_to_bytes(report[1].decode()) == target.encode(), data

    print("Nushell integration passed")


def check_init_features(binary):
    env = os.environ.copy()
    env["STATUSBAR_LINES"] = "1"
    env["STATUSBAR_STATE"] = "/statusbar-session-indicator"
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
            cfg.write(f"""[line.1]
left = VALUE #[track]#(value)#[notrack]
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
            cfg.write(f'''[line.1]
left = #(value)
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
        config_path = os.path.join(folder, "bar.config")
        with open(config_path, "w") as config_file:
            config_file.write("[line.1]\nleft = LOG_BAR\n")
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
    original = b'# original comment\n[line.1]\nleft = "initial text"'  # No final newline.
    replacement = b'# live replacement\n[line.1]\nleft = next\n[line.2]\nright = %H:%M\n'
    clean_env = os.environ.copy()
    clean_env.pop("STATUSBAR_STATE", None)
    clean_env.pop("STATUSBAR_SESSION_ID", None)
    clean_env["STATUSBAR_CONFIG"] = "/does/not/exist/statusbar-config"
    builtin = subprocess.run([binary, "config", "--default"], env=clean_env, capture_output=True, check=True).stdout
    result = subprocess.run([binary, "config", "--print", "default"], input=b"invalid", env=clean_env, capture_output=True)
    assert result.returncode == 0 and result.stdout == builtin, result
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
subprocess.run([binary, 'set', '1', 'MANUAL_OVERRIDE'], check=True)
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
nested_text = b'[line.1]\nleft = nested\n'
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
            config_path = os.path.join(folder, "initial.config")
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
assert b"EXAMPLES" in help_result.stdout and b"statusbar config < my.config" in help_result.stdout
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
        with open(replacement, "rb") as source:
            result = subprocess.run([binary, "config"], stdin=source, capture_output=True)
        assert not result.stdout and result.returncode == 0, result
        print(f"__LOAD__:{result.returncode}", flush=True)
    elif command == "STDIN":
        result = subprocess.run([binary, "config"], input=b'[line.1]\nleft = FROM_STDIN\n', capture_output=True)
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
        first = "[line.1]\nleft = ORDER_ONE\n[line.2]\nleft = ORDER_TWO\n"
        final = "[line.1]\nleft = FINAL_ONE\n[line.2]\nleft = FINAL_TWO\n"
        slot = b"\x1b]1337;SetUserVar=StatusBarSlot4=S0VFUA==\x1b\\"
        os.write(1, frame(first) + slot + frame(final))
        print("__ORDER__", flush=True)
    elif command == "SAVED":
        os.write(1, b"\x1b7")
        emit('[line.1]\nleft = AFTER_RESTORE\n')
        time.sleep(.01)
        os.write(1, b"\x1b8")
        print("__SAVED__", flush=True)
    elif command == "HELD":
        os.write(1, b"\x1b7")
        emit('[line.1]\nleft = AFTER_PAUSE\n')
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
            data = read_until(master, data, b"KEEP", timeout=5)
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
text = ''.join('[line.%d]\nleft = ROW%d\n' % (n, n) for n in range(1, 6))
envelope = b'1;' + os.environ['STATUSBAR_SESSION_ID'].encode() + b';' + text.encode()
frame = b'\x1b]3110;STATUSBAR;CONFIG;' + base64.b64encode(envelope) + b'\x1b\\'
os.write(1, frame + b'\nAFTER_CONFIG\n')
time.sleep(.3)
'''
    config = "[line.1]\nleft = BEFORE_BAR\n[line.2]\n"
    script = f"printf %s {shlex.quote(config)} | " + shlex.join([binary, "-c", "-", "--", sys.executable, "-c", child])
    pid, master = spawn(["/bin/sh", "-c", script], rows=24)
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
    command = "printf '[line.1]\\nleft = BAR\\n' | " + shlex.join([binary, "-c", "-", "--", "/bin/sh", "-c", script])
    code, data = capture_pty(["/bin/sh", "-c", command], timeout=4)
    assert code == 3, (code, data[-500:])
    assert b"LAST_WORDS" in data, data[-500:]
    assert time.monotonic() - started < 3
    print("a background job holding the pty does not keep the session open")


def check_push_pop(binary):
    child = r'''
import os, subprocess, sys, time
b = sys.argv[1]
def run(*args, **kwargs):
    result = subprocess.run([b, *args], capture_output=True, **kwargs)
    assert result.returncode == 0, (args, result.returncode, result.stderr)
    return result.stdout
first = run('push', input=b'partial\rfirst final\n').strip()
second = run('push', input='Καλημέρα ## #[bold]'.encode()).strip()
assert first == b'1' and second == b'2', (first, second)
with open(os.environ['STATUSBAR_STATE'], 'rb') as state:
    state.readline()
    assert state.readline() == b'lines 1\n'
print('PUSHED_TWO', flush=True)
run('config', input=b'[line.1]\nleft = reloaded\n[line.2]\nright = new\n')
time.sleep(.1)
run('pop', first.decode())
assert run('pop', first.decode()) == b''
print('POPPED_FIRST', flush=True)
p = subprocess.Popen([b, 'push'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
p.stdin.write(b'in progress')
p.stdin.flush()
time.sleep(1.0)
run('pop', '3')
p.stdin.write(b'\rfinished')
p.stdin.close()
assert p.wait(timeout=4) == 0, p.stderr.read()
assert p.stdout.read() == b'3\n'
simultaneous = [subprocess.Popen([b, 'push'], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                for _ in range(2)]
for stream, value in zip(simultaneous, (b'left', b'right')):
    stream.stdin.write(value)
    stream.stdin.close()
ids = []
for stream in simultaneous:
    assert stream.wait(timeout=5) == 0, stream.stderr.read()
    ids.append(stream.stdout.read().strip())
assert set(ids) == {b'4', b'5'}, ids
for row_id in ids:
    run('pop', row_id.decode())
empty = run('push', input=b'').strip()
assert empty == b'6', empty
run('pop', empty.decode())
wide = run('push', input=b'#' * 74 + b' 99.9%').strip()
assert wide == b'7', wide
time.sleep(.1)
run('pop', wide.decode())
command = subprocess.run([b, 'push', '--', sys.executable, '-c',
                          'import os,sys; '
                          'sys.stdout.write("started\\n"); sys.stdout.flush(); '
                          'w=int(os.environ["COLUMNS"]); '
                          'sys.stderr.write("#" * (w-6) + " 99.9%\\r"); '
                          'sys.exit(7 if w==76 else 9)'], capture_output=True)
assert command.returncode == 7, (command.returncode, command.stderr)
assert command.stdout == b'8\n', command.stdout
assert command.stderr == b'', command.stderr
time.sleep(.1)
run('pop', '8')
assert run('pop', second.decode()) == b''
wrong = os.environ.copy()
wrong['STATUSBAR_SESSION_ID'] = '0' * 32
assert subprocess.run([b, 'pop', '2'], env=wrong, capture_output=True).returncode != 0
print('PUSH_POP_OK', flush=True)
'''
    config = b'[line.1]\nleft = configured\n'
    with tempfile.NamedTemporaryFile(delete=False) as cfg:
        cfg.write(config)
        path = cfg.name
    try:
        code, data = capture_pty([binary, '-c', path, '--', sys.executable,
                                  '-c', child, binary], timeout=12)
        assert code == 0 and b'PUSH_POP_OK' in data, data[-2500:]
        assert b'[1]' in data and b'first final' in data, data[-2500:]
        assert b'[2]' in data and 'Καλημέρα ## #[bold]'.encode() in data, data[-2500:]
        assert b'reloaded' in data and b'[3]' in data and b'in progress' in data, data[-700:]
        assert b'[7]' in data, data[-700:]
        assert b'[8]' in data and b'99.9%' in data, data[-700:]
    finally:
        os.unlink(path)
    print('push/pop streams, command width, stable IDs, reloads, active removal, and authentication passed')


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: multirow_pty.py STATUSBAR")
    binary = os.path.abspath(sys.argv[1])
    check_set_dash(binary)

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
    check_stdin_config(binary)
    check_osc7_titles(binary)
    check_zsh(binary)
    check_fish(binary)
    check_nu(binary)
    check_init_features(binary)
    check_tracking(binary)
    check_tracking(binary, colors=True)
    check_geometry_results_do_not_highlight(binary)
    check_resize_command_runs(binary)
    check_adaptive_palette(binary)
    check_logging(binary)
    check_config_snapshots(binary)
    check_osc_config(binary)
    check_theme_growth(binary)
    check_background_job_exit(binary)
    check_push_pop(binary)
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

    print("multirow PTY checks passed")


if __name__ == "__main__":
    main()
