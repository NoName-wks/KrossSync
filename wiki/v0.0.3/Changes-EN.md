# v0.0.3 changes

[한국어](Changes-KO) · [English](Changes-EN)

[Home](Home-EN) · [Guild tutorial](Tutorial-EN) · [API](API-EN)

## Source baseline

This local draft is based on `source/NEXT VERSION/V0.0.3/KrossSync.luau`. The [reference source](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KrossSync.luau) is pinned to commit `bf2cd0a`. It does not assume a separate v0.0.3 release tag.

## Compared with v0.0.2

| Item | v0.0.2 | v0.0.3 |
| --- | --- | --- |
| Automatic polling | The next cycle waits for every key's task to finish | Each key is scheduled independently |
| Polling exceptions | Task cleanup can be interrupted | Task state is cleared so another poll can run |
| `UnSync` persistence | Attempted when the shared server list is empty | Attempted even when other server IDs remain |
| `UnSync` save source | Value retained inside the update callback | Latest wrapper committed by the MemoryStore update |
| Newer durable value | Rejection of an old shared snapshot can make release fail | Newer value is preserved and release succeeds |

## Release behavior and cost

`UnSync` removes the current JobId from the shared server list and persists the committed wrapper's `data` to DataStore. Remaining server IDs no longer cause persistence to be skipped, addressing the case where records of stopped servers prevent a surviving server from saving during release.

It does not add a separate MemoryStore `GetAsync`. Each ordinary release path can issue a DataStore `UpdateAsync` request; an identical snapshot can cancel the write. Retries after request errors consume additional requests.

A durable-save failure retains the local value for retry. If `SaveData` returns `stale` because a newer durable version exists, that value is preserved and the key is released. This does not guarantee recovery if every server abruptly stops before persistence.

## Preserved contracts

- DataStore holds `data` for ordinary keys; MemoryStore and `LastData` hold the full wrapper. Removed durable keys retain tombstones.
- `Set` persists first, then shares, returning `(dataSaved, memorySaved)`.
- `SetMemory` updates the full wrapper without immediately persisting it. Put temporary values in `memory`.
- `Save` checks its 60-second condition during calls. `true` does not always mean durable persistence completed.
- The 15-second polling interval, 300-second shared durable-check interval, and 60-second validation-lease takeover interval are retained. They do not guarantee exact recovery times.
- `GetData` can preserve unsaved shared changes in the returned `data`; that value alone cannot establish whether a particular request was durably committed.
- `OnNewData` reports the latest state change found by polling. It does not deliver every intermediate change or a deletion-specific event.

## Validation records

The following results are preserved in the existing `V0.0.3_TEST_RESULTS.json` and `V0.0.3_NOTES.md`. They were not rerun while preparing this wiki.

- 70 mock-storage checks with an accelerated clock passed: 62 existing regression checks, two polling isolation/recovery checks, five release checks, and one crash-model check.
- Focused checks against actual storage services passed. Independent instances in a Studio Edit session verified persistence of the latest shared value and protection of newer durable data. This was not an actual server-crash test.
- The two-live-server normal-shutdown run `V3N_0925634e499e` passed on 2026-10-18 with the same PlaceVersion 1039 and distinct JobIds.
- The first server recorded `close.ready=true` and `close.completed=true`; the second recorded `passed=true` and `complete=true`.
- Checks covered concurrent `Set`, concurrent `SetMemory`, latest shared-data persistence through `UnSync`, write/removal races, load, injected-error retries, and recovery.
- Both servers recorded zero request errors and zero load-write failures. Four pre-commit MemoryStore failures were injected per server.
- Recorded recovery times were 71 seconds for lease takeover, 294 seconds for durable values, and 296 seconds for tombstones, with one automatic durable read per recovery key. These are observations from that run, not time or capacity guarantees.

Actual abrupt server termination, real service response loss, production-scale load, and long-term stability remain unverified. Abrupt-exit validation requires a separate run with a new RunId and `ExitMode="Abrupt"`.

## Before applying

1. Choose one English or Korean module from the v0.0.3 folder.
2. If several players on one server share a guild, release the key only after its last local use.
3. Persist important changes immediately with `Set`. If release fails, stop new writes and retry.
4. Validate mixed-version operation separately.
5. Exclude test scripts and `Tests` from production deployment. If scripts were only disabled in Studio, separately check that the change reached the published Place.
