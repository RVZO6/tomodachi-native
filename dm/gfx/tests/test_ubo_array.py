#!/usr/bin/env python3
# 合成 MSL 的資源表改寫測試；不帶遊戲著色器。
# Resource-table rewrite tests with synthetic MSL, without game shaders.
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from dmsh_ubo_array import rewrite

SOURCE = '''struct spvDescriptorSetBuffer0 {
    array<texture2d<float>, 32> fp_t2d_cb3_0 [[id(40)]];
    array<sampler, 32> fp_t2d_cb3_0Smplr [[id(72)]];
    constant float4* fp_c3 [[id(104)]];
};
void example() {
    uint _10 = min(uint(_8), 31u);
    int _12 = int(_10);
    uint _30 = min(uint(_28), 31u);
    float4 x = args.fp_t2d_cb3_0[_12].sample(args.fp_t2d_cb3_0Smplr[_12], float2(0));
}
'''


class UniformArrays(unittest.TestCase):
    def test_table_pointer_and_abi(self):
        result = rewrite(SOURCE)
        self.assertIn('constant spvUboArray_fp_t2d_cb3_0* fp_t2d_cb3_0 [[id(0)]];', result)
        self.assertIn('constant spvUboArray_fp_t2d_cb3_0Smplr* fp_t2d_cb3_0Smplr [[id(1)]];', result)
        self.assertIn('constant float4* fp_c3 [[id(2)]];', result)
        self.assertIn('uint n;\n    array<texture2d<float>, 1> e;', result)

    def test_only_descriptor_index_clamp_removed(self):
        result = rewrite(SOURCE)
        self.assertIn('uint _10 = uint(_8);', result)
        self.assertIn('uint _30 = min(uint(_28), 31u);', result)
        self.assertIn('(&args.fp_t2d_cb3_0->e[0])[min(uint(_12), args.fp_t2d_cb3_0->n)]', result)
        self.assertIn('(&args.fp_t2d_cb3_0Smplr->e[0])[min(uint(_12), args.fp_t2d_cb3_0Smplr->n)]', result)

    def test_other_uniform_slots_unchanged(self):
        source = SOURCE.replace('_cb3_0', '_cb7_0')
        self.assertEqual(rewrite(source), source)

    def test_idempotent(self):
        self.assertEqual(rewrite(rewrite(SOURCE)), rewrite(SOURCE))

    def test_no_argument_buffer(self):
        self.assertEqual(rewrite('kernel void nothing() {}'), 'kernel void nothing() {}')


if __name__ == '__main__':
    unittest.main()
