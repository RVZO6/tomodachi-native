#!/usr/bin/env python3
# 按構建號檢查補丁登記；可選用玩家自己的 NSO 檢查全部原指令，不需要提交遊戲資料。
# Check build-gated patch registries; optionally verify every original instruction against the player's NSOs, without committing game data.
import ast
import os
from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[3]
BASE = '56bf85bd535413464cb75bb6c2683b67'
UPDATE = 'b39fef373fb12154385d012aab3bc99e'


def registries():
    result = {}
    for node in ast.parse((ROOT / 'dm/tools/patch_nso.py').read_text()).body:
        if not isinstance(node, ast.Assign):
            continue
        target = node.targets[0]
        if isinstance(target, ast.Name) and target.id in ('CUTS', 'OPTIONS', 'PARAMS', 'ASPECT', 'MARKER'):
            result[target.id] = ast.literal_eval(node.value)
        elif isinstance(target, ast.Subscript) and isinstance(target.value, ast.Name) and target.value.id == 'PARAMS':
            result['PARAMS'][ast.literal_eval(target.slice)] = ast.literal_eval(node.value)
    return result


class BuildPatches(unittest.TestCase):
    def setUp(self):
        self.r = registries()

    def test_both_versions_have_all_features(self):
        for build in (BASE, UPDATE):
            self.assertEqual(len(self.r['CUTS'][build]), 2)
            self.assertEqual(len(self.r['OPTIONS'][build]['fps60']), 1)
            self.assertEqual(len(self.r['PARAMS'][build]), 5)
            self.assertEqual(len(self.r['MARKER'][build]), 2)
            self.assertEqual(len(self.r['ASPECT'][build]), 3)

    def test_unknown_build_gets_no_fixed_addresses(self):
        for registry in self.r.values():
            self.assertNotIn('0' * 32, registry)

    def test_original_base_sites_stay_unchanged(self):
        self.assertEqual([r[0] for r in self.r['CUTS'][BASE]], [0x3f774c, 0x3f77c0])
        self.assertEqual(self.r['OPTIONS'][BASE]['fps60'][0][:3], (0x28b35c, '092440b9', '34008052'))
        self.assertEqual(self.r['ASPECT'][BASE], (0x8ce854, 0x1e204068, 0x205c88))
        self.assertEqual(self.r['MARKER'][BASE], [(0x350fac, 0x2d2f07a0, 21), (0x21721e8, 0xa9434ff4, 20)])

    def test_inlined_room_marker_not_naive_offset(self):
        self.assertEqual(self.r['MARKER'][UPDATE][0], (0x3228a8, 0x2d3587a0, 21))
        self.assertNotEqual(self.r['MARKER'][UPDATE][0][0], 0x322710)

    def test_profile_keeps_base_and_sdk_identity(self):
        rows = [r.split('\t') for r in (ROOT / 'dm/games/010051F0207B2000/game.tsv').read_text().splitlines()]
        builds = {r[1]: r[2:] for r in rows if r[0] == 'build'}
        self.assertEqual(builds['v0'][1], 'main=' + BASE)
        self.assertEqual(builds['v262144'][1], 'main=' + UPDATE)
        self.assertEqual(builds['v0'][2], builds['v262144'][2])
        self.assertIn(['shader_versions', 'v0 v262144'], rows)

    @unittest.skipUnless(os.environ.get('TOMODACHI_WORK'), 'set TOMODACHI_WORK to check private NSOs')
    def test_private_original_instructions(self):
        import lz4.block
        for version, build in (('v0', BASE), ('v262144', UPDATE)):
            nso = (Path(os.environ['TOMODACHI_WORK']) / f'data/{version}/ExeFS/main').read_bytes()
            self.assertEqual(nso[0x40:0x50].hex(), build)
            flags = struct.unpack_from('<I', nso, 0xc)[0]
            fo, mo, size = struct.unpack_from('<III', nso, 0x10)
            self.assertEqual(mo, 0)
            text = nso[fo:fo + struct.unpack_from('<I', nso, 0x60)[0]]
            if flags & 1:
                text = lz4.block.decompress(text, uncompressed_size=size)
            sites = [(off, bytes.fromhex(original)) for off, original, *_ in self.r['CUTS'][build]]
            sites += [(off, bytes.fromhex(original)) for off, original, *_ in self.r['OPTIONS'][build]['fps60']]
            for oa, wa, ob, wb, *_ in self.r['PARAMS'][build]:
                sites.append((oa, struct.pack('<I', int(wa, 16))))
                if ob is not None:
                    sites.append((ob, struct.pack('<I', int(wb, 16))))
            off, word, caller = self.r['ASPECT'][build]
            sites.append((off, struct.pack('<I', word)))
            branch = struct.unpack_from('<I', text, caller - 4)[0]
            self.assertEqual(branch & 0xfc000000, 0x94000000)
            delta = branch & 0x3ffffff
            if delta & (1 << 25):
                delta -= 1 << 26
            self.assertEqual(caller - 4 + delta * 4, off - 0x1c)
            sites += [(off, struct.pack('<I', word)) for off, word, _ in self.r['MARKER'][build]]
            for off, expected in sites:
                self.assertEqual(text[off:off + len(expected)], expected, f'{version} +{off:#x}')
            fps = self.r['OPTIONS'][build]['fps60'][0][0]
            self.assertEqual(text[fps + 4:fps + 20], bytes.fromhex('144000b90a0dd41a5f01096b0a5000b9'))


if __name__ == '__main__':
    unittest.main()
