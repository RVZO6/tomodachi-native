# Tomodachi Life version compatibility

## Scope

The profile accepts v1.0.0 (`v0`) and v1.0.4 (`v262144`). The default package
is v1.0.4. Both versions contribute to one shader library. This is an
implementation and validation record, not a claim of complete gameplay coverage.

The base remains kuosuko/tomodachi-native at `5587d1bd`. Its Metal 4 backend,
TBDR optimizations, frame pacing, audio renderer, Mac frontend, iPad frontend,
touch input and signed-page optional-patch mechanism are retained.

## Sources checked

- [spider-blok/nxnative](https://github.com/spider-blok/nxnative/tree/0ed8b12cdf30182558bdb3dfaf25f91b1bcee044):
  v1.0.4 build identity and shader evidence. Its profile and renderer are not
  drop-in replacements. The terrain texture-synthesis changes described in its
  game notes are not present in that source revision.
- [nxnative PR 1075](https://github.com/seedds/nxnative/pull/1075): profile and
  shader tables, not an implementation of the documented texture-synthesis fix.
- [MacNativeGames](https://github.com/ly05010419/MacNativeGames/tree/64baa886/games/tomodachi):
  depth-feedback snapshots provided the model for the Mii-lighting correction.
  Its v1.0.0 pool-alignment and larger Mii/cloth heaps are not copied: this host
  has a different allocation path, and their need here has not been established.
- nxnative's `pool_arrays` in `dm/gfx/tools/dmsh_build.py` provided the resource
  table layout: a length followed by 8-byte Metal resource IDs. Here the source
  is a bound uniform buffer, not the global descriptor pool.

No textures, game shaders, keys or extracted game binaries are added to source.

## Binary findings

The private base and merged update were extracted with integrity checks.

- Main build IDs: `56bf85bd535413464cb75bb6c2683b67` (v1.0.0),
  `b39fef373fb12154385d012aab3bc99e` (v1.0.4).
- The SDK binary is byte-identical: build ID
  `651781821e2c2e0b2bdfe905e8676f56` (SDK 20.5.3).
- The update adds one undefined main symbol, `nn::ngc::CountNumbers(char16_t const*)`.
  The unchanged SDK defines it at `0x3f6990`; it counts Unicode numeric characters
  directly, without IPC. It does not need a service stub.
- RomFS has 66,343 files in each version; 51 differ. The union contains 14,389
  shader keys. One effect fragment shader is replaced in the update; both keys
  and both vertex/fragment pairs are retained. Existing package indices stay.

All fixed-address patches remain build-gated and assert original instructions.
The base main rewrite was compared with the unmodified rewriter's output and
is byte-identical. The renderer corrections below apply to both versions.

### Relocated code

| Feature | v1.0.0 | v1.0.4 |
|---|---|---|
| Touch-pointer permission reads | `3f774c`, `3f77c0` | `4014ec`, `401560` |
| Optional 60 FPS | `28b35c` | `27f518` |
| Docked render-size pair | `8eee2c`, `8eee34` | `8b736c`, `8b7374` |
| Swapchain-size pair | `903710`, `903714` | `8df6b0`, `8df6b4` |
| Crop width / heights | `46e93c`, `46e928`, `46ed70` | `481bb8`, `481ba4`, `481fec` |
| Projection aspect | `8ce854` | `897d64` |
| Main-camera return site | `205c88` | `3a9ec` |
| Room world-to-UI marker | `350fac` | `3228a8` |
| Shared world-to-UI marker | `21721e8` | `2117258` |

The room projection is inlined in v1.0.4. The function mapper's approximate
`322710` result is wrong. Disassembly identifies the result store at `3228a8`,
with the projection still in x21. The trampoline saves/restores s3/s4 there.
The 60 FPS site still precedes storing interval w20 and calculating `60 / w20`;
it changes game timing, not only host presentation frequency.

## Graphics corrections

### Terrain descriptor indices

The generated GameField fragment shader calculates handle offsets such as
`(layer << 8) + 272` and `+296`, then divides by eight. Even layer zero requires
indices 34 and 37. The translator's fixed 32-entry array clamps both to 31.

`dmsh_ubo_array.py` converts the affected translated `*_cb3_0` arrays into bounded
resource-table pointers. It follows only those descriptor indices when removing
the old clamp; unrelated clamps remain. The translated cb3 corresponds to NVN
uniform slot 0. The host derives table length from the bound buffer, resolves
original texture/sampler handles, and appends a dummy sentinel for out-of-range
access. Argument IDs are renumbered after arrays become pointers, and reflection
is regenerated from the same MSL used for compilation. No ABI-only metadata
change, guessed 256-entry limit, synthetic grass or embedded game texture is used.

### Depth attachment feedback

Sampling an active depth attachment now uses a stored snapshot, as colour
feedback already did. Pending clears land first. Hazard detection includes all
uniform-handle-array elements. Read-only draws can reuse the same-pass depth
snapshot; a depth write or pass boundary invalidates it. Existing colour-feedback
copy pooling, view handling and resource lifetime rules remain in use.

## Build selection

```sh
python3 scripts/build_mac_app.py 010051F0207B2000 -w /path/to/work \
  -p v262144 -o '/path/to/Tomodachi Life 1.0.4.app'
python3 scripts/build_mac_app.py 010051F0207B2000 -w /path/to/work \
  -p v0 -o '/path/to/Tomodachi Life 1.0.0.app'
```

The NSP-to-IPA script already has `-p`. Its shader-input list now requires both
the base and v1.0.4; package `-p v0` still selects base game code and RomFS.
Use separate output apps, and back up saves before switching game versions.
Do not use `--keep-data` to carry one version's RomFS into the other.

## Validation

Reproducible source tests, without game files:

```sh
python3 -m unittest discover -s dm/tools/tests -v
python3 -m unittest discover -s dm/gfx/tests -p test_ubo_array.py -v
make -C dm/host GAME=010051F0207B2000 game_profile
make -C dm/gfx/tests GAME=010051F0207B2000 t_depth_feedback t_ubo_table
./dm/gfx/tests/t_depth_feedback
./dm/gfx/tests/t_ubo_table
```

With private originals and Python `lz4`, also set `TOMODACHI_WORK` to the
workspace containing `data/v0/ExeFS` and `data/v262144/ExeFS`. The build-registry
test then verifies every registered original instruction in both actual NSOs.

Tests run on an Apple M4 Pro:

- Six build-registry tests, including actual NSO instruction checks.
- Five synthetic MSL transformation tests, including ABI member renumbering,
  descriptor-only clamp removal, other-slot preservation and idempotence.
- 444 real-GPU depth-snapshot checks across D16, D32F and D32F/S8.
- Real-GPU resource-table reads at 0, 31, 34, 37 and 63; bounded dummy reads at
  64 and 8191; actual uniform length and offset checks; feedback at element 37.
- Existing touch, gesture, binding, aspect, audio, audio-SPSC and pad-map tests.
- The existing RT-range GPU test passes all 19 checks with `DM_NVN_TBDR=1`;
  the read-only depth eligibility test passes four CPU checks. Default optimization
  settings are unchanged.
- The inherited `t_reorder_chain` test has 46 failures out of 155 on this system.
  A separately compiled copy of the original renderer has the same 46 failures.
  This is not reported as a passing test or fixed by this update.

The complete inherited host test target cannot run unchanged: it references
removed files such as `touch_mac.c` and `dm_cursor.c`, and requires another
private game's binaries. Targeted applicable tests are used instead.

## Build results and remaining shader gaps

The combined library build produces 14,382 Mac and 14,382 iOS libraries from
14,389 shader keys. The new v1.0.4 effect shader compiles. All 21 terrain-table
variants pass the production Metal argument-layout check; the GPU table test
passes 35 checks when that private-library validation is enabled.

Seven inherited shader failures remain: geometry stages `3e558ebcd49f7b7e`,
`7b76b956408e43bf`, `99d4fa6451ac93c4`; SPIRV-Cross failures
`21251a51a67f3609`, `219e658643856080`; and Metal bracket-depth failures
`4c40d646d71beaf3`, `fa9619c1f371dde8`. In addition, 188 variants still have
unsupported global-pool bindless bindings (`fp_t3d_cb0_40000000` /
`fp_s_cb0_40000000`). These are not the uniform-buffer terrain arrays fixed
here. None of the 21 corrected terrain variants has an unresolved binding. No claim of full shader coverage is made.

The unsigned Release IPA builds for device families 1 and 2 with a minimum OS
of 26.0. ZIP CRC validation passes. Its embedded `__dmmaino0` alternative code
page is 16 KiB and contains the checked v1.0.4 `mov w20,#1` FPS instruction.
The Mac host's ad-hoc signature verifies.

The installed iOS 27.0 SDK cannot declare the fork's iOS 27.1 hinge/reserved-region
APIs. Compile-time SDK guards retain those paths when built with SDK 27.1 or
newer; older SDKs build the existing non-fold layout. Runtime availability checks
alone do not solve missing declarations. New-SDK/Duo behavior still needs testing.

## Longer Mac startup run

A separate 85-second v1.0.4 run with isolated saves and scripted button input
reached the 3D island exploration tutorial. The 1920x1080 screenshots show grass/
clover texture, water, trees, plot outlines and the tutorial UI. This is a visual
sanity check, not a pixel-accuracy comparison or full gameplay test. The SDK audio
renderer processed non-silent audio frames; physical speaker output was not tested.
The run shut down cleanly without missing-library or unsupported-binding errors.

In addition to the 8-bit-index warning, this run reported a texture mip-count clamp
and a uniform-handle read with a pending GPU write but no tracked CPU data copy.
That path reads current CPU contents. These warnings remain documented limitations;
correctness for all such updates is not established by the startup screenshots.

## Actual-game and hardware checks still required

Both versions also completed bounded 35-second headless Mac startup runs with
separate test saves and rendered screenshots. v1.0.4 used the 60 FPS option and
1920x1200 output (16:10); v1.0.0 used 30 FPS and 1920x1080. Both reached the
first-run date/time confirmation menu and shut down cleanly. One inherited
warning remained: expanding an 8-bit index buffer with a pending GPU write reads
current contents. This is not a gameplay or sustained-performance benchmark. A separate 45-second
v1.0.4 run used a scripted touch to accept the date/time menu and button input
to advance through region selection to currency selection. Screenshots confirm
these transitions at 16:10. This does not cover all touch scenes.

Compilation and synthetic GPU tests do not prove full gameplay or performance.
Check both versions, and record platform, OS, settings and logs:

- Fresh startup, island selection/naming, Mii creation and native keyboard submit/cancel.
- Grass/clover layers, plot borders, Mii face/hair/clothing highlights, water and sky.
- Photo capture and dream bubbles; inherited geometry-shader gaps are not claimed fixed.
- Mouse/touch selection, finger-ID reuse, Mii editing, controller navigation and reconnect.
- 30/60 FPS at normal game speed, including audio and animation timing.
- 16:9, wide and tall output, UI markers, spotlight capture and touch alignment.
- Save/reload, backup restore, long play, memory use, thermal load and frame times.
- Physical iPad: launch, signed optional 60 FPS pages, multi-touch, keyboard,
  orientation, suspend/resume, audio and memory-pressure behavior.

No iPad installation or device signing is performed without the owner's request.
No claim of full compatibility, sustained 60 FPS or no regression follows from
build success alone.
