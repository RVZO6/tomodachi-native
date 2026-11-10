# Native iPad/iPhone Mii import and export

## Using it

Open **HOME → Settings → Save Data**. The paired **Import Mii** and **Export Mii**
actions are native controls, not the HTML prototype.

1. Create and save a placeholder islander in the game if you do not want to
   replace an existing one. The importer does not create islanders.
2. Open **Import Mii → Choose from Files** and select a ShareMii `.ltd` v3 file.
3. The reserved preview area shows one identity group (head, name, filename),
   with **Replace** as the separate action. The islander list does not move.
4. Select the saved islander to replace. Replace stays active after selecting a
   file; without a destination it gives a selection prompt instead of greying out.
5. Press **Replace**, check the destination, and confirm **Replace Mii**.
6. The replacement is queued. Save any game progress you want to keep, then
   close and reopen the game. The import uses the latest committed save at boot,
   not an earlier snapshot taken while browsing files.

Only the selected Mii's design and personal settings are changed. Other slots,
relationships, memories, map data, and unrelated save fields are not rewritten.
A backup of the whole current island is verified before installing the result.
The previous save appears in Backups as **Kept before Mii import**.

**Export Mii** selects an initialized islander and creates a `.ltd` file through
the iPad Files export picker. It does not edit the island. Source `.ltd` files
are read only; selecting a file alone never edits the save.

## Current limits

- Only standard ShareMii **v3** files are accepted. Other versions are rejected.
- Face paint requires a complete canvas/texture pair, or neither. Each must be
  one valid Zstandard frame with the measured decoded sizes (262,144 and 131,072
  bytes), a bounded window, and no trailing payload. Dictionaries, unknown-sized
  frames and partial pairs are not supported.
- The input limit is 2 MiB. Save version/header, field counts, bounds, aliasing,
  UTF-16 and relevant slider/flag values are checked before any save write.
  This is not a complete semantic validator for every possible appearance value;
  use files from sources you trust and retain the backup.
- The importer accepts only initialized slots 1–70. It never allocates a new
  islander. Shared face-paint references are not overwritten; a free paint slot
  is used instead, or the import is refused.
- Portraits are the centered game silhouette fallback. No independent Mii
  renderer has been implemented or verified. The importer does not call paused
  guest rendering functions or claim to render real headshots.
- Physical-iPad behavior and full gameplay across every imported design remain
  hardware checks. Simulator UI tests are not evidence of physical-device speed.

## Implementation and provenance

`dm_mii_codec.c` is a native, bounded implementation of the public
[ShareMii v3 layout](https://github.com/Star-F0rce/ShareMii/wiki/Technical).
The save-field hash mapping and opaque normalization details were measured by
black-box export/import comparisons on private copies using the installed
ShareMii v3.2.3 CLI. ShareMii's GPL implementation was not copied or embedded.
No Python runtime is shipped. No game files or user saves are checked in.

Fields are located through the save's own hash/offset index, not version-specific
absolute offsets. Mii arrays have 70 entries; paint metadata has 72. The wire
header contains version and paint-presence bytes. The final v3 preference word
contains three byte booleans, mapped into the save's 210-bit packed array without
changing neighboring islanders. UTF-16 format-control bytes used by valid names
are preserved in data and removed only for native display text.

The Zstandard **decoder only** is pinned at upstream v1.5.7, under its BSD license.
It validates face-paint payloads without executing the guest SDK. Its symbols are
hidden from the game's host resolver. The license is included in the built app.

## Save transaction

The native panel snapshots committed data under the existing host commit lock.
Confirmation validates against that snapshot and stores an immutable import file,
its SHA-256, and the selected destination's fingerprint in `.mii-imports/<UUID>`.
Only one save change can be pending. A changed destination or tampered queued
file is rejected instead of silently replacing a different Mii.

Before guest startup, the transaction:

1. Reads and validates the latest committed save.
2. Edits a separate staging copy; validates the result and bounded paint files.
3. Creates and verifies a full before-import backup.
4. Persists the expected output hashes and backup identity in the job journal.
5. Atomically swaps the complete save directories with `renamex_np(RENAME_SWAP)`.
6. Verifies the installed output before clearing the pending action.

There is no interval with half-written save files or a missing committed directory.
If killed after the swap, the next boot recognizes the installed output instead of
applying the same import twice. Prepared recovery data is retained after an
uncertain failure; a missing backup is not a reason to delete that recovery copy.
Cancellation of an unapplied queued job does not modify the save.

## Validation

```sh
make -C dm/ios/tests run
```

- 477 synthetic codec checks under AddressSanitizer and UndefinedBehaviorSanitizer,
  including truncated/malformed files, unknown versions, UTF-16, schema bounds,
  uninitialized/out-of-range targets, unknown-field preservation, paint framing,
  exhaustion and mutation of compressed payloads.
- 15 isolated Foundation transaction tests, including verified backups, preserving
  progress saved after queueing, changed targets, tampered plans/files, symlinks,
  storage/backup failure, cancellation, and interruption before/after atomic swap.
- Five private reference-tool comparisons: Mii.sav and Player.sav are byte-identical
  for no-op import, ordinary replacement, adding paint, replacing paint, and
  removing paint. These tests use external private copies, never live saves.
- A private imported save completed a bounded 30-second v1.0.4 Mac boot with clean
  shutdown. Existing renderer warnings remained; this is not a full gameplay test.
- iPad Pro simulator, iOS 27.0: native Files selection, v3 parsing, active Replace
  prompt, target selection, confirmation, queue without changing live save,
  restart application, original-byte backup, and installing both paint files.
- Native before/after captures show unchanged question and islander-button frames
  when a file is selected. Button text is centered by glyph bounds; silhouettes
  are cropped to visible content before display.

The unsigned device IPA still requires the owner's signing/sideloading process.
No physical-device signing or installation is performed by these tests.

## Integration contract

`dm_mii_ltd` is a borrowed view. Its immutable input buffer must outlive every
consumer; it is not an owning object or a safe deferred-callback allocation.
The current `dm_mii_slot.initialized` value checks stored identity/name data, not
live game occupancy. Do not use it as the allocator or occupancy authority for a
new-islander path. `dm_mii_apply` remains replacement-only, with zero-based slots
0–69 and its existing-record guard intact. No creation ABI, guest callback, runtime
occupancy mutation, or new-islander implementation is enabled in this checkpoint.

## Separate new-islander work

Importing a file as a **new** islander is not enabled. It must use the game's normal creation and placement sequence, not this replacement path or writes to empty save slots. See [the disabled integration checkpoint and runtime evidence](MII_NEW_ISLANDER.md).
