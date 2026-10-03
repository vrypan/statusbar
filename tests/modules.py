#!/usr/bin/env python3
"""Exercise shipped module commands with local data, then compose them in a PTY."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap

import multirow_pty as terminal


ROOT = Path(__file__).resolve().parent.parent
MODULES = ROOT / "samples/modules"
ANSI = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;;[^\x1b]*\x1b\\")

# Substitute the providers, not the module commands or their awk/jq parsers.
MOCK = r'''
import json, os, pathlib, sys, time
name = pathlib.Path(sys.argv[0]).name
mode = os.environ.get('MODULE_CASE', '')
if name == 'uname': print('Linux' if mode == 'linux' else 'Darwin')
elif name == 'whoami': print('alice')
elif name == 'hostname': print('laptop')
elif name == 'uptime':
    print('12:00 up 3 days, load average: 0.25, 1.50, 2.75' if mode == 'linux'
          else '12:00 up 3 days, load averages: 0.25 1.50 2.75')
elif name == 'df':
    print('Filesystem 1024-blocks Used Available Capacity Mounted on')
    print('/dev/disk1 1000000 950000 50000 95% /')
elif name == 'sysctl': print(16 * 1024**3)
elif name == 'top':
    print('CPU usage: 1.0% user, 2.0% sys, 97.0% idle')
    print('PhysMem: 10G used (1G wired), 6G unused.')
    print('CPU usage: 12.0% user, 8.0% sys, 80.0% idle')
    print('PhysMem: 12G used (2G wired), 4G unused.')
elif name == 'pmset':
    if mode == 'desktop': print("Now drawing from 'AC Power'")
    else:
        print("Now drawing from 'Battery Power'")
        print(' -InternalBattery-0 (id=123) 12%; discharging; 0:50 remaining present: true')
elif name == 'route':
    if mode != 'offline': print('  interface: en0')
elif name == 'netstat':
    counter = pathlib.Path(os.environ['MODULE_COUNTER'])
    n = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(n+1))
    rx = 1000 + (n % 2) * 2048
    tx = 1000 + (n % 2) * 1024
    print('Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll')
    print(f'en0 1500 <Link#4> aa:bb:cc:dd:ee:ff 10 0 {rx} 20 0 {tx} 0')
elif name == 'sleep': pass
elif name == 'curl':
    if mode == 'offline': sys.exit(22)
    if mode == 'invalid': print('not json'); sys.exit(0)
    url = next(arg for arg in sys.argv if arg.startswith('https://'))
    if 'wttr.in' in url: print(('Athens: ' if '%l' in ' '.join(sys.argv) else '') + '☀ +24°C')
    elif 'topstories' in url: print('[123]')
    else: print(json.dumps({'title': 'A useful\nheadline'}))
elif name == 'gh':
    if mode == 'offline': sys.exit(1)
    item = {'repository': {'full_name': 'org/repo'}, 'subject': {'title': 'Review\nready'}}
    print(json.dumps([] if mode == 'empty' else [item] * (100 if mode == 'many' else 2)))
elif name == 'codex-usage':
    assert sys.argv[1:] == ['snapshot', '--json'], sys.argv
    if mode == 'offline': sys.exit(1)
    if mode == 'invalid': print('not json'); sys.exit(0)
    week = {'usedPercent': 95 if mode == 'exhausted' else 75 if mode == 'warning' else 49,
            'windowDurationMins': 10080, 'resetsAt': 1 if mode == 'exhausted' else time.time() + 90000}
    bucket = {'primary': week, 'credits': {'balance': '0'}}
    if mode == 'secondary':
        bucket.update(primary={'usedPercent': 10, 'windowDurationMins': 300}, secondary=week)
    if mode == 'unlimited': bucket['credits'] = {'unlimited': True}
    if mode == 'available': bucket['credits'] = {'hasCredits': True}
    state = {'limits': {'rateLimitsByLimitId': {'codex': bucket},
                        'rateLimitResetCredits': {'availableCount': 3}},
             'usage': {'summary': {'lifetimeTokens': 7702301849}}}
    if mode == 'missing': state = {}
    if mode == 'other-bucket': state['limits'] = {'rateLimits': {'limitId': 'other'}}
    if mode == 'limits-error': state['limitsError'] = 'unavailable'
    if mode == 'usage-error': state['usageError'] = 'unavailable'
    if mode == 'zero':
        week['usedPercent'] = 0
        state['limits']['rateLimitResetCredits']['availableCount'] = 0
        state['usage']['summary']['lifetimeTokens'] = 0
    print(json.dumps({'version': 1, 'state': state}))
else: raise AssertionError(name)
'''


def command_text(path):
    match = re.search(r"^run = \|\n((?:[ \t].*\n|\n)+)", path.read_text(), re.M)
    return textwrap.dedent(match[1]) if match else None


def main():
    binary = str(Path(sys.argv[1]).resolve())
    assert shutil.which('jq'), 'module fixture checks require jq'
    files = sorted(MODULES.glob('*.statusbar'))
    assert len(files) == 11
    for path in files:
        assert f'[line.{path.stem}.' in path.read_text(), path
        assert '<module>' not in path.read_text(), path
        subprocess.run([binary, 'config', 'check', str(path)], check=True, capture_output=True)
        command = command_text(path)
        if command:
            subprocess.run(['/bin/sh', '-n'], input=command, text=True, check=True, capture_output=True)
        assert not re.search(r'#[0-9a-fA-F]{6}\b|38;[25];|48;[25];', path.read_text()), path
        assert all(int(n) <= 15 for n in re.findall(r'colour(\d+)', path.read_text())), path
        installed = ROOT / 'zig-out/share/statusbar/modules' / path.name
        assert installed.read_bytes() == path.read_bytes(), installed

    with tempfile.TemporaryDirectory() as directory:
        mockdir = Path(directory) / 'bin'
        mockdir.mkdir()
        provider = mockdir / 'provider'
        provider.write_text(f'#!{sys.executable}\n' + MOCK)
        provider.chmod(0o755)
        for name in ('uname', 'whoami', 'hostname', 'uptime', 'df', 'sysctl', 'top',
                     'pmset', 'route', 'netstat', 'sleep', 'curl', 'gh', 'codex-usage'):
            (mockdir / name).symlink_to(provider.name)
        env = {**os.environ, 'PATH': f'{mockdir}:' + os.environ.get('PATH', ''),
               'CODEX_USAGE_BIN': str(mockdir / 'codex-usage'),
               'MODULE_COUNTER': str(Path(directory) / 'counter')}

        def run(name, mode=''):
            result = subprocess.run(['/bin/sh', '-c', command_text(MODULES / f'{name}.statusbar')],
                                    env={**env, 'MODULE_CASE': mode}, capture_output=True,
                                    text=True, timeout=10)
            assert result.returncode == 0, (name, mode, result.stderr)
            assert result.stdout and '\n' not in result.stdout, (name, result.stdout)
            return result.stdout, ANSI.sub('', result.stdout)

        assert run('host')[1] == 'alice@laptop'
        assert run('load')[1] == run('load', 'linux')[1] == '0.25  1.50  2.75'
        raw, text = run('disk')
        assert '95%' in text and '\x1b[31m' in raw, raw
        raw, text = run('compute')
        assert '20%' in text and '12.0/16G' in text, text
        raw, text = run('battery')
        assert '12%' in text and '↓ BAT' in text and '\x1b[31m' in raw, raw
        assert run('battery', 'desktop')[1] == 'AC'
        assert '2 KiB/s' in run('network')[1]
        assert run('network', 'offline')[1] == 'no route'
        for name in ('compute', 'battery', 'network'):
            assert run(name, 'linux')[1] == 'macOS only'
        assert '+24°C' in run('weather')[1]
        assert run('weather', 'offline')[1] == 'unavailable'
        raw, text = run('hackernews')
        assert 'item?id=123' in raw and text == 'A useful headline', raw
        assert run('hackernews', 'invalid')[1] == 'unavailable'
        assert run('hackernews', 'offline')[1] == 'unavailable'
        assert run('github', 'empty')[1] == '✓ inbox clear'
        assert run('github')[1] == '2 unread · org/repo: Review ready'
        assert run('github', 'many')[1].startswith('100+ unread')
        assert run('github', 'offline')[1].startswith('unavailable')
        raw, text = run('codex')
        assert len(raw.encode()) <= 512, raw
        assert '\x1b[32m' in raw and '49%' in text and '1d1h' in text, raw
        assert all(value in text for value in ('credits 0', 'resets 3', 'tokens ∑ 7.7B lifetime')), text
        assert '49%' in run('codex', 'secondary')[1]
        assert '\x1b[33m' in run('codex', 'warning')[0]
        raw, text = run('codex', 'exhausted')
        assert '\x1b[31m' in raw and '95%' in text and 'refreshing' in text, raw
        assert 'credits ∞' in run('codex', 'unlimited')[1]
        assert 'credits available' in run('codex', 'available')[1]
        text = run('codex', 'zero')[1]
        assert all(value in text for value in ('0%', 'credits 0', 'resets 0', 'tokens ∑ 0 lifetime')), text
        for mode in ('missing', 'other-bucket', 'limits-error'):
            text = run('codex', mode)[1]
            assert all(value in text for value in ('7d —', '↻ —', 'credits —', 'resets —')), text
        assert '7.7B' in run('codex', 'limits-error')[1]
        assert 'tokens ∑ —' in run('codex', 'usage-error')[1]
        for mode in ('offline', 'invalid'):
            assert run('codex', mode)[1] == '⚠ usage unavailable'
        result = subprocess.run(['/bin/sh', '-c', command_text(MODULES / 'codex.statusbar')],
                                env={**env, 'CODEX_USAGE_BIN': str(mockdir / 'absent')},
                                capture_output=True, text=True)
        assert result.stdout == 'install codex-usage', result
        # Missing dependencies give a readable state before any request.
        (mockdir / 'curl').unlink()
        result = subprocess.run(['/bin/sh', '-c', command_text(MODULES / 'weather.statusbar')],
                                env={**env, 'PATH': str(mockdir)}, capture_output=True, text=True)
        assert result.stdout == 'install curl', result
        (mockdir / 'curl').symlink_to(provider.name)
        print('modules: shell syntax, native colors, packaging, provider fixtures and failures')

        child = terminal.CHILD_PRELUDE + r'''
import json, pathlib
library = pathlib.Path(sys.argv[2])
for path in sorted(library.glob('*.statusbar')):
    run('config', 'import', str(path))
    settle()
deadline = time.monotonic() + 5
while True:
    lines = json.loads(run('ls', '--json'))['lines']
    if len(lines) == len(list(library.glob('*.statusbar'))) + 1 or time.monotonic() >= deadline: break
    time.sleep(.05)
assert len(lines) == len(list(library.glob('*.statusbar'))) + 1 and all(line['visible'] for line in lines), lines
assert {line['name'].split('.')[0] for line in lines[1:]} == {path.stem for path in library.glob('*.statusbar')}, lines
snapshot = run('config', 'show')
assert '<module>' not in snapshot, snapshot
definitions = json.loads(run('config', 'show', '--json'))
assert {line['name'].split('.')[0] for line in definitions['lines'][1:]} == {path.stem for path in library.glob('*.statusbar')}, definitions
run('config', 'import', '-', input=(library / 'clock.statusbar').read_bytes(), code=2)
run('config', 'import', str(library / 'clock.statusbar'), code=2)
assert run('config', 'show') == snapshot
time.sleep(2)
for line in lines[1:]:
    name = line['name']
    mark('OVERRIDE_START_' + name)
    run('update', name, 'OVERRIDE_' + name)
    mark('OVERRIDE_SET_' + name)
    run('update', name, '--reset')
    mark('OVERRIDE_RESET_' + name)
mark('MODULE_LIBRARY_OK')
'''
        code, data = terminal.run_session(binary, '[line.base]\ntext = MODULES\n', child,
                                          str(MODULES), env=env, timeout=20)
        assert code == 0 and b'MODULE_LIBRARY_OK' in data, data[-5000:]
        visible = terminal.plain(data)
        for path in files:
            name = re.search(r'^\[line\.(.+)\]$', path.read_text(), re.M)[1]
            before = ('OVERRIDE_START_' + name).encode()
            after = ('OVERRIDE_SET_' + name).encode()
            reset = ('OVERRIDE_RESET_' + name).encode()
            assert ('OVERRIDE_' + name).encode() in terminal.between(visible, before, after)
            assert ('OVERRIDE_' + name).encode() not in terminal.between(visible, after, reset)
        for expected in (b'alice@laptop', b'0.25  1.50', b'95%', b'12.0/16G', '+24°C'.encode(),
                         b'A useful headline', b'2 unread', b'KiB/s', b'7.7B'):
            assert expected in visible, (expected, visible[-5000:])
        print('modules: static names, duplicate rejection and saved snapshots render correctly')


if __name__ == '__main__':
    main()
