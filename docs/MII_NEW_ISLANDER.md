# Imported LTD files as new islanders: integration checkpoint

## Status

**Not an enabled feature.** There is no new-islander import button or live guest creation backend. The first milestone—exactly one imported new islander that survives normal save, close, and reload—has **not** passed. The replacement importer remains separate and replacement-only.

This checkpoint starts at `37b40afdeef13ff8b78416356e7261dcd7e262cf`. It adds shared input ownership, independent creation preflight, and an isolated Mac runtime runner. It does not call a guest allocation function, write an empty save slot, fabricate a profile, or require a placeholder for future creation.

## Shared input and separate routes

- `dm_mii_input_open` copies the complete file **before** it calls the existing parser. Parsed views, names, and compressed paint frames refer only to the owner's immutable copy. Close the owner after its last use. Native replacement callers use scope cleanup, including error and recovery paths.
- `dm_mii_input_replace` passes that validated view to the unchanged `dm_mii_apply`. Its initialized-slot guard, backup, queue, and atomic swap procedures remain in place. Queue storage uses a copy of the exact validated bytes.
- `dm_mii_new_plan_make` is independent of replacement. It decodes neutral data: 152 appearance bytes, all 18 LTD scalars in file order, both names, and the three preference bytes. The owner retains the complete original file, including flags, unknown metadata, and paint frames. **Keep the owner; the decoded plan is not a complete substitute.**
- Preflight rejects every matching stored source identity, including records whose names are invalid. It does not generate IDs. A roster with 70 initialized stored records is rejected. These checks do not establish live occupancy or progression eligibility.
- `dm_mii_new_can_execute` always returns false, including when a caller clears every gap bit. No build is enabled. Plan success means only that neutral data was prepared; it is not permission to mutate the island.

The research prototype's partial profile-byte patcher was deliberately not added to production. A zeroed byte array is not a game-constructed profile. Its strings have self-pointers; reset is not construction, and copying a constructed profile can invalidate those pointers.

## Isolated Mac runtime

Build only in the implementation worktree:

```sh
make -C dm/host GAME=010051F0207B2000 dmhost
```

Use a new directory under the current harness scratch area. Do not use an active save, application bundle, or another thread's scratch. Substitute local read-only asset paths:

```sh
python3 dm/tools/mii_new_runtime.py \
  --game 010051F0207B2000 \
  --root "$SCRATCH/new-islander-runtime" \
  --patched "$ASSETS/build/patched_v262144" \
  --romfs "$ASSETS/data/v262144/RomFS" \
  --msl "$ASSETS/build/cache/metal_shader_cache" \
  --font "$ASSETS/build/font" \
  --seconds 90 --trace --keys '6:A,8:A'
```

The tool:

1. Requires an explicit game and a known `main.fixups.tsv` build ID. Probe offsets are in the game profile's `mii_creation_trace.tsv`, not a shared host address table. These are observation points, not a creation adapter.
2. Requires a nonexistent root, or `--resume` with its own disposable-root marker. It rejects input/runtime overlap and symlinks on resume. There is no active-save copy or save-seed option.
3. Creates an independent `.app` and a root-specific bundle ID. It sets a private HOME, preferences home, cache, temporary directory, working directory, save, PSO list, and logs. It does not inherit diagnostic environment switches.
4. Starts the host through `sandbox-exec`. Writes are denied outside that root; network access is denied. It tests one permitted and one denied write before launch. Shared patched modules, tables, fonts, and game assets remain outside the writable area.
5. Places `DM_SAVE` at `run/save`. Transaction siblings such as `save.work` and `save.new` remain inside `run/`, not beside an active island. An exclusive lock prevents concurrent use of the same root. The host inherits the lock descriptor.
6. Records a local host hash, build ID, exit status, logs, and periodic screenshots. It terminates only its own subprocess at the selected time. Logs and screenshots can contain private paths, names, and game data: **do not commit or upload them**.

`DM_KEYS` steps execute in listed order; repeat expansion does not sort steps by time. Do not put an early stick action after a long series of repeated A presses. Use the existing control names, such as `StickLUp~1`, `StickRLeft~1`, and `Plus`. `--keyboard` supplies synthetic text. `--window` is optional; it does not make the active game app part of this test.

Do not remove the sandbox to make UI automation work. On the test machine, computer-use discovery could not attach to the sandbox-launched app. Headless rendering and scripted controls worked. No existing simulator session or signed device build was used.

## Evidence from this checkpoint

### Synthetic host tests

Run:

```sh
make -C dm/ios/tests run
```

- **773 creation-preflight assertions**, with AddressSanitizer, UndefinedBehaviorSanitizer, and warnings as errors. Coverage includes input ownership, exact scalar/name/preference retention, every truncated plain input, malformed values, all 70 duplicate positions with and without valid names, advisory full capacity, unchanged plan output on failure, paired paint-frame ownership, and unconditional execution denial.
- **477 existing codec assertions**, with both sanitizers.
- **15 replacement transaction tests**, including uninitialized target rejection, invalid inputs, backups, queued progress, interrupted swaps, and recovery. These now use the owning replacement route.
- **5 isolation tests**, including real macOS sandbox execution of a synthetic host. They verify write denial outside the run root, permitted save siblings, environment isolation, input overlap rejection, known/unknown build gates, marker validation, and symlink rejection. The synthetic host does not execute game instructions.

### Static and mocked evidence

The independent read-only research tools were rerun against this worktree:

- Two original image hashes/build IDs, 13 unique exact normalized function matches, and 11 selected instruction contracts passed.
- Five original-instruction emulation cases passed with **mocked game services**. This is not real allocation, callback completion, house placement, or save proof. On allocation failure, the game clears occupancy but retains copied appearance; it does not provide full rollback.

The creation ABI remains statically established: x0 points to an eight-byte object-handle destination; x1 points to 152 appearance bytes; x2 points to a constructed profile; x8 points to a separate four-byte roster-slot destination. Callback cloning retains borrowed pointers, not deep copies. Return from the request function is not a lifetime boundary.

### Actual runtime evidence

An independently built Mac host ran the v1.0.4 game with a disposable empty save root, read-only shared assets, and verified write restrictions. It rendered the date screen, island tour, synthetic island naming, and the normal “Add a Mii” flow. Build-gated probes hit the profile constructor.

This is a **partial normal-creation trace**, not a successful imported creation. It does not confirm the live x8 result, callback/request lifetimes, placement completion, or save/reload persistence. No imported islander was created. v1.0.0 was statically checked but was not runtime-tested for this work.

## Required work before activation

1. Finish a normal creation trace on the disposable island. Capture controlled editor/profile changes and exports. Confirm misc fields, sexuality/preferences, birthday and direct-age modes, and voice preset/custom-mode semantics. Preserve every LTD field; reject input that cannot be represented without loss.
2. Establish sequence eligibility, guest-thread scheduling, request/callback completion, and all buffer/resource lifetimes. HOME fully pauses the guest; do not promise completion there. Preserve introduction and house placement.
3. Add a separate build-gated guest adapter and an operation journal. Distinguish pending, preparation, request, callback, placement, normal save, reload verification, and failure. Do not add guessed function-pointer calls or empty-slot file writes.
4. Before mutation, make and verify a full backup using the existing storage concepts. Do not restore files under a running guest mount. Later-stage failures need a proven game teardown or closed-game recovery procedure, not occupancy-only cleanup.
5. Start with no paint and reject duplicate source IDs. Complete all mappings before enabling even this mode. Paint needs the editor resource pipeline (type 8, 72 records); compressed LTD frames are not guest resource pointers.
6. Require exactly one added islander after normal save/close/reload. Compare every exported field, appearance, voice/personality, house state, and old islanders' fields/relations. Explain any global progression change. A commit counter alone is not proof.
7. Exercise empty, full, and progression-locked islands; invalid input; duplicates; cancellation; and allocation, callback, resource, and save failures. Repeat for both known builds. Top-level normalized matches do not establish identical birthday/application dependencies.

Until these checks pass, the live backend and user-facing creation option must remain absent or disabled. Portrait rendering is out of scope.
