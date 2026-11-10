#!/usr/bin/env python3
# 新居民研究的獨立 Mac 執行器；檔案寫入僅准許在本次目錄內。
# Isolated Mac runner for new-islander research; file writes are restricted to this run's directory.
"""Run a separate host with an empty disposable island. Never seed or patch a save."""
import argparse
import fcntl
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

REPO = Path(__file__).resolve().parents[2]
GAME = '010051F0207B2000'
# 僅供觀測的已確認入口；不是建立居民的配接器。
# Verified observation entry points only; this is not an islander-creation adapter.
def load_probes():
    path = REPO / 'dm/games' / GAME / 'mii_creation_trace.tsv'
    lines = [line.split('\t') for line in path.read_text().splitlines() if line and not line.startswith('#')]
    if lines[0] != ['build_id', 'create', 'created_callback', 'create_state', 'convert', 'construct']:
        raise ValueError('Invalid creation-trace table.')
    result = {}
    for row in lines[1:]:
        if len(row) != 6 or row[0] in result:
            raise ValueError('Invalid creation-trace build row.')
        for offset in row[1:]:
            if not 0 < int(offset, 16) < 0x10000000:
                raise ValueError('Invalid creation-trace offset.')
        result[row[0]] = ','.join(row[1:])
    return result


PROBES = load_probes()
MARKER = '.mii-new-disposable.json'


def policy(root):
    # JSON 字串的引號與反斜線跳脫也適用於此處的 Sandbox 字串。
    # JSON string escaping of quotes and backslashes also applies to these Sandbox strings.
    return ('(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n'
            f'(allow file-write* (subpath {json.dumps(str(root))}) (literal "/dev/null"))\n')


def build_id(patched):
    lines = (patched / 'main.fixups.tsv').read_text().splitlines()
    values = [s.split('\t')[1] for s in lines if s.startswith('# BUILD_ID\t')]
    if len(values) != 1 or values[0] not in PROBES:
        raise ValueError('Unknown main build; no fixed-address probes are permitted.')
    return values[0]


def initialize(root, resume, inputs):
    # 所有輸入都必須在寫入範圍之外；包含 shader 與 patched 清單。
    # Every input must remain outside the writable area, including shader and patched tables.
    if any(p == root or root in p.parents or p in root.parents for p in inputs):
        raise ValueError('Read-only inputs must be outside the runtime root.')
    if resume:
        if root.is_symlink() or not root.is_dir():
            raise ValueError('Resume requires a marked disposable runtime root.')
        if any(p.is_symlink() for p in root.rglob('*')):
            raise ValueError('Disposable runtime must not contain symlinks.')
        marker = json.loads((root / MARKER).read_text())
        if marker != {'version': 1, 'disposable': True, 'game': GAME}:
            raise ValueError('Not a recognized disposable runtime root.')
    else:
        root.mkdir(mode=0o700, parents=False, exist_ok=False)
        (root / MARKER).write_text(json.dumps({'version': 1, 'disposable': True, 'game': GAME}))
    for name in ('home', 'cache', 'tmp', 'logs', 'run', 'run/save', 'run/temp'):
        (root / name).mkdir(parents=True, exist_ok=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game', required=True, choices=[GAME], help='Explicit game profile; no default')
    p.add_argument('--root', required=True, type=Path, help='New, nonexistent directory; all save siblings stay here')
    p.add_argument('--resume', action='store_true', help='Reuse only a marked disposable root')
    p.add_argument('--host', type=Path, default=REPO / 'dm/host/dmhost')
    for name in ('patched', 'romfs', 'msl', 'font'):
        p.add_argument('--' + name, required=True, type=Path)
    p.add_argument('--seconds', type=float, default=60)
    p.add_argument('--keys', default='', help='DM_KEYS steps in execution order, not automatically sorted')
    p.add_argument('--keyboard', default='Test', help='Synthetic name for the headless keyboard')
    p.add_argument('--window', action='store_true', help='Open only this independent host window')
    p.add_argument('--trace', action='store_true', help='Build-gated normal-creation probes; logs can contain private data')
    a = p.parse_args()
    if sys.platform != 'darwin' or not Path('/usr/bin/sandbox-exec').is_file():
        p.error('Requires macOS sandbox-exec; do not run without the write restriction.')
    if not 1 <= a.seconds <= 1800:
        p.error('--seconds must be between 1 and 1800.')
    root = a.root.expanduser().absolute()
    if root != root.resolve() or any(c in str(root) for c in ('%', ':', '\n')):
        p.error('Runtime path must be canonical, without symlinks or parent traversal.')
    inputs = [v.expanduser().resolve(strict=True) for v in (a.host, a.patched, a.romfs, a.msl, a.font)]
    host, patched, romfs, msl, font = inputs
    bid = build_id(patched)
    initialize(root, a.resume, inputs + [REPO])
    lock = (root / 'run.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    sandbox = root / 'runtime.sb'
    sandbox.write_text(policy(root))
    # 先測試允許與拒絕；只用全新的自有測試檔，不嘗試寫共用資源。
    # Test both permission and denial using new owned probe files, never shared assets.
    inside = root / 'write-probe'
    outside = root.parent / ('mii-deny-probe-' + uuid.uuid4().hex)
    base = ['/usr/bin/sandbox-exec', '-f', str(sandbox)]
    allowed = subprocess.run(base + ['/usr/bin/touch', str(inside)], capture_output=True)
    denied = subprocess.run(base + ['/usr/bin/touch', str(outside)], capture_output=True)
    if outside.exists():
        outside.unlink()
        raise RuntimeError('Write restriction failed; host was not started.')
    if allowed.returncode or not denied.returncode:
        raise RuntimeError('Cannot verify write restriction; host was not started.')
    inside.unlink()
    bundle_id = 'org.nxnative.mii-new-test.' + hashlib.sha256(str(root).encode()).hexdigest()[:12]
    app = root / 'New Islander Test.app'
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True, exist_ok=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle_id, 'CFBundleName': 'New Islander Test',
        'CFBundleExecutable': 'new-islander-host', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1'}))
    exe = macos / 'new-islander-host'
    shutil.copyfile(host, exe)
    exe.chmod(0o700)
    tag = uuid.uuid4().hex
    manifest = {'scope': 'Normal runtime observation only; no imported-islander proof',
                'build_id': bid, 'host_sha256': hashlib.sha256(exe.read_bytes()).hexdigest(),
                'bundle_id': bundle_id, 'write_restriction_tested': True, 'trace': a.trace, 'seconds': a.seconds}
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(root / 'home'),
           'CFFIXED_USER_HOME': str(root / 'home'), 'TMPDIR': str(root / 'tmp') + '/',
           'XDG_CACHE_HOME': str(root / 'cache'), 'DM_ROOT': str(root),
           'DM_SAVE': str(root / 'run/save'), 'DM_TEMP': str(root / 'run/temp'),
           'DM_ROMFS': str(romfs), 'DM_MSL_DIR': str(msl), 'DM_FONT_DIR': str(font),
           'DM_NVN_SHMAP': str(REPO / 'dm/games' / GAME / 'shader_map.tsv'),
           'DM_PSO_USER': str(root / 'run/pso_user.tsv'), 'DM_TACT_PREFETCH': '0',
           'DM_LANG': 'en-US', 'DM_KEYS': a.keys, 'DM_KBD': a.keyboard,
           'DM_NVN_SHOT': ','.join(str(n) for n in range(300, int(a.seconds*30), 300)) +
                          ':' + str(root / 'logs' / (tag + '-%d.png'))}
    if a.window:
        env['DM_WINDOW'] = '1'
    if a.trace:
        env['DM_PROBE'] = ','.join('main:' + v for v in PROBES[bid].split(','))
    log = root / 'logs' / (tag + '.log')
    with log.open('w') as out:
        proc = subprocess.Popen(base + [str(exe), str(patched)], cwd=root / 'run', env=env,
                                stdout=out, stderr=subprocess.STDOUT, pass_fds=(lock.fileno(),))
        try:
            code = proc.wait(timeout=a.seconds)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            proc.terminate()
            try:
                code = proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                code = proc.wait()
    manifest['exit_code'] = code
    (root / 'logs' / (tag + '.json')).write_text(json.dumps(manifest, indent=2) + '\n')
    print('Runtime log:', log)
    print('No imported-islander persistence result is claimed.')
    return 0 if code == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
