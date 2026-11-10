#!/usr/bin/env python3
# 不用遊戲資料測試隔離執行器與版本閘門。
# Test runner isolation and build gates without game data.
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).resolve().parents[2] / 'tools/mii_new_runtime.py'
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('mii_runtime', TOOL)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeIsolation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mii-isolation-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.assets = self.base / 'assets'
        self.assets.mkdir()
        self.root = self.base / 'runtime'

    def test_build_gate(self):
        fixups = self.assets / 'main.fixups.tsv'
        for bid in runtime.PROBES:
            fixups.write_text('# BUILD_ID\t' + bid + '\n')
            self.assertEqual(runtime.build_id(self.assets), bid)
        for text in ('', '# BUILD_ID\tunknown\n', '# BUILD_ID\t' + bid + '\n# BUILD_ID\t' + bid):
            fixups.write_text(text)
            with self.assertRaises(ValueError):
                runtime.build_id(self.assets)

    def test_fresh_and_marked_resume(self):
        runtime.initialize(self.root, False, [self.assets])
        self.assertTrue((self.root / 'run/save').is_dir())
        self.assertTrue((self.root / 'run').is_dir())
        runtime.initialize(self.root, True, [self.assets])
        with self.assertRaises(FileExistsError):
            runtime.initialize(self.root, False, [self.assets])
        (self.root / runtime.MARKER).write_text('{}')
        with self.assertRaises(ValueError):
            runtime.initialize(self.root, True, [self.assets])

    def test_input_overlap(self):
        for inputs in ([self.root / 'assets'], [self.base], [self.root]):
            with self.assertRaises(ValueError):
                runtime.initialize(self.root, False, inputs)
        self.assertFalse(self.root.exists())

    def test_symlink_resume(self):
        runtime.initialize(self.root, False, [self.assets])
        (self.root / 'escape').symlink_to(self.assets, target_is_directory=True)
        with self.assertRaises(ValueError):
            runtime.initialize(self.root, True, [self.assets])

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS sandbox-exec')
    def test_real_sandbox_synthetic_host(self):
        (self.assets / 'main.fixups.tsv').write_text('# BUILD_ID\t' + next(iter(runtime.PROBES)) + '\n')
        forbidden = self.assets / 'must-not-exist'
        host = self.base / 'host'
        host.write_text('#!/bin/sh\n'
                        'test -z "$UNSAFE_INHERITED_VALUE" || exit 9\n'
                        'test "$HOME" = "$CFFIXED_USER_HOME" || exit 8\n'
                        '/usr/bin/touch "$DM_SAVE/created" "$DM_SAVE.work" "$DM_SAVE.new" || exit 7\n'
                        f'/usr/bin/touch {shlex.quote(str(forbidden))}\n'
                        f'test ! -e {shlex.quote(str(forbidden))}\n')
        cmd = [sys.executable, str(TOOL), '--game', runtime.GAME, '--root', str(self.root), '--host', str(host), '--seconds', '3']
        for name in ('patched', 'romfs', 'msl', 'font'):
            cmd += ['--' + name, str(self.assets)]
        env = dict(os.environ, UNSAFE_INHERITED_VALUE='not-inherited')
        result = subprocess.run(cmd, capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / 'run/save/created').is_file())
        self.assertTrue((self.root / 'run/save.work').is_file())
        self.assertTrue((self.root / 'run/save.new').is_file())
        self.assertFalse(forbidden.exists())
        manifests = list((self.root / 'logs').glob('*.json'))
        self.assertEqual(len(manifests), 1)
        manifest = json.loads(manifests[0].read_text())
        self.assertTrue(manifest['write_restriction_tested'])
        self.assertEqual(manifest['exit_code'], 0)
        self.assertEqual(subprocess.run(cmd, capture_output=True).returncode, 1)
        self.assertEqual(subprocess.run(cmd + ['--resume'], capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
