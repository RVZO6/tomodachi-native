#!/usr/bin/env python3
# 所有寫入都在帶標記的暫存副本；中斷測試不碰玩家存檔。
# All writes use marked temporary copies; interruption tests never touch a player's save.
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
import uuid

HERE = Path(__file__).resolve().parent
CODEC = HERE / 'build/t_mii_codec'
STORE = HERE / 'build/mii_store_cli'


def hashes(folder):
    return {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in folder.rglob('*') if p.is_file()}


def field(data, tag):
    end = struct.unpack_from('<I', data, 8)[0]
    for off in range(0x28, end, 8):
        key, pointer = struct.unpack_from('<II', data, off)
        if key == tag:
            return pointer + 4
    raise AssertionError('missing field')


class MiiTransactions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native-mii-')
        self.root = Path(self.temp.name) / ('test-' + uuid.uuid4().hex)
        subprocess.run([str(CODEC), '--emit-fixture', str(self.root)], check=True, capture_output=True)
        self.before = hashes(self.root / 'save')
        self.suite = 'org.nxnative.mii-test.' + self.root.name
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(lambda: subprocess.run(['defaults', 'delete', self.suite], capture_output=True))

    def run_store(self, *args, code=0, interrupt=None):
        env = dict(os.environ)
        if interrupt:
            env['DM_MII_TEST_INTERRUPT'] = interrupt
        result = subprocess.run([str(STORE), str(self.root), *args], env=env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def queue(self, paint=False, slot=2):
        return self.run_store('queue', str(self.root / ('Alex-Facepaint.ltd' if paint else 'Alex.ltd')), str(slot))

    def backups(self):
        return [p for p in (self.root / 'Backups').glob('*') if p.is_dir() and not p.name.startswith('.')]

    def plan(self):
        plans = list((self.root / '.mii-imports').glob('*/plan.plist'))
        self.assertEqual(len(plans), 1)
        return plans[0]

    def test_queue_is_not_a_live_save_edit(self):
        self.queue()
        self.assertEqual(hashes(self.root / 'save'), self.before)
        self.assertFalse(self.backups())
        self.run_store('cancel')
        self.assertEqual(hashes(self.root / 'save'), self.before)
        self.assertFalse(list((self.root / '.mii-imports').glob('*')))

    def test_apply_and_byte_preserving_backup(self):
        self.queue()
        self.run_store('apply')
        self.assertNotEqual(hashes(self.root / 'save')['Mii.sav'], self.before['Mii.sav'])
        self.assertEqual(hashes(self.root / 'save')['Map.sav'], self.before['Map.sav'])
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(hashes(self.backups()[0]), self.before)
        self.assertFalse(list((self.root / '.mii-imports').glob('*')))
        self.run_store('export', '2', str(self.root / 'exported.ltd'))
        self.assertEqual((self.root / 'exported.ltd').read_bytes(), (self.root / 'Alex.ltd').read_bytes())

    def test_latest_saved_progress_is_preserved(self):
        self.queue()
        (self.root / 'save/progress.dat').write_bytes(b'progress after queuing the import')
        latest = hashes(self.root / 'save')
        self.run_store('apply')
        self.assertEqual((self.root / 'save/progress.dat').read_bytes(), b'progress after queuing the import')
        self.assertEqual(hashes(self.backups()[0]), latest)

    def test_facepaint_payloads_are_installed(self):
        self.queue(paint=True)
        self.run_store('apply')
        files = sorted((self.root / 'save/Ugc').glob('UgcFacePaint000.*.zs'))
        self.assertEqual(len(files), 2)
        self.assertTrue(all(p.stat().st_size > 0 for p in files))
        self.assertEqual(hashes(self.backups()[0]), self.before)
        self.run_store('export', '2', str(self.root / 'paint-export.ltd'))
        data = (self.root / 'paint-export.ltd').read_bytes()
        self.assertEqual(data[:4], b'\x03\x01\x01\x00')

    def test_changed_target_is_not_overwritten(self):
        self.queue()
        path = self.root / 'save/Mii.sav'
        data = bytearray(path.read_bytes())
        data[field(data, 0x881ca27a) + 156 + 4] ^= 0x40
        path.write_bytes(data)
        latest = hashes(self.root / 'save')
        self.run_store('apply', code=1)
        self.assertEqual(hashes(self.root / 'save'), latest)
        self.assertFalse(self.backups())

    def test_tampered_queued_file_is_rejected(self):
        self.queue()
        p = self.plan().parent / 'incoming.ltd'
        p.write_bytes(p.read_bytes() + b'tampered')
        self.run_store('apply', code=1)
        self.assertEqual(hashes(self.root / 'save'), self.before)
        self.assertFalse(self.backups())

    def test_bad_plan_type_fails_without_writing_save(self):
        self.queue()
        p = self.plan()
        data = plistlib.loads(p.read_bytes())
        data['slot'] = ['not a slot']
        p.write_bytes(plistlib.dumps(data))
        self.run_store('apply', code=1)
        self.assertEqual(hashes(self.root / 'save'), self.before)

    def test_invalid_file_cannot_be_queued(self):
        p = self.root / 'Alex.ltd'
        data = bytearray(p.read_bytes())
        data[0] = 4
        p.write_bytes(data)
        self.run_store('queue', str(p), '2', code=1)
        self.assertEqual(hashes(self.root / 'save'), self.before)
        self.assertFalse((self.root / '.mii-imports').exists())

    def test_uninitialized_slot_is_not_a_target(self):
        self.run_store('queue', str(self.root / 'Alex.ltd'), '5', code=1)
        self.assertEqual(hashes(self.root / 'save'), self.before)

    def test_second_pending_change_is_not_silently_overwritten(self):
        self.queue()
        original = self.plan().read_bytes()
        self.run_store('queue', str(self.root / 'Alex.ltd'), '3', code=1)
        self.assertEqual(self.plan().read_bytes(), original)
        self.assertEqual(hashes(self.root / 'save'), self.before)

    def test_no_backup_means_no_import(self):
        self.queue()
        (self.root / 'Backups').write_bytes(b'not a directory')
        self.run_store('apply', code=1)
        self.assertEqual(hashes(self.root / 'save'), self.before)

    def test_symlink_in_save_is_rejected(self):
        self.queue()
        outside = self.root / 'outside.txt'
        outside.write_bytes(b'do not change')
        (self.root / 'save/link').symlink_to(outside)
        self.run_store('apply', code=1)
        self.assertEqual(outside.read_bytes(), b'do not change')
        self.assertTrue((self.root / 'save/link').is_symlink())
        self.assertEqual(hashes(self.root / 'save')['Mii.sav'], self.before['Mii.sav'])

    def test_interruption_before_swap_preserves_original(self):
        self.queue()
        self.run_store('apply', code=77, interrupt='after-prepare')
        self.assertEqual(hashes(self.root / 'save'), self.before)
        self.assertEqual(len(self.backups()), 1)
        self.run_store('apply')
        self.assertNotEqual(hashes(self.root / 'save')['Mii.sav'], self.before['Mii.sav'])
        self.assertTrue(all(hashes(p) == self.before for p in self.backups()))

    def test_interruption_after_swap_is_not_applied_twice(self):
        self.queue()
        self.run_store('apply', code=77, interrupt='after-swap')
        installed = hashes(self.root / 'save')
        self.assertNotEqual(installed['Mii.sav'], self.before['Mii.sav'])
        self.assertEqual(len(self.backups()), 1)
        self.run_store('apply')
        self.assertEqual(hashes(self.root / 'save'), installed)
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(hashes(self.backups()[0]), self.before)

    def test_missing_backup_retains_recovery_copy(self):
        self.queue()
        self.run_store('apply', code=77, interrupt='after-swap')
        p = self.plan()
        recovery = p.parent / 'save.prepared'
        self.assertEqual(hashes(recovery), self.before)
        shutil.rmtree(self.backups()[0])
        self.run_store('apply', code=1)
        self.assertTrue(recovery.is_dir())
        self.assertEqual(hashes(recovery), self.before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
