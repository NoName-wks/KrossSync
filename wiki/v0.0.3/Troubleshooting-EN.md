# Troubleshooting and known limits

[한국어](Troubleshooting-KO) · [English](Troubleshooting-EN)

Draft documentation for v0.0.3, based on the [v0.0.3 working copy](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KrossSync.luau).

## Known limits

- Updates across DataStore and MemoryStore are not atomic.
- `onlineServers` is not an exclusive session lock.
- `SetMemory` and `OnNewData` do not guarantee delivery of every intermediate change.
- MemoryStore-only changes may be lost through expiration or related-server shutdown.
- Durable checks are reserved at a 300-second interval per key but can be delayed by errors or lease takeover.
- Functional write callbacks may run repeatedly. Avoid external side effects.
- Stale snapshots are not automatically merged.
- Shutdown cleanup does not guarantee a final durable save.
- Two real servers passed normal-shutdown checks; actual abrupt termination, real service response loss, production-scale load, and long-term stability remain unverified.

## Signal module not found

Install [Signal+](https://github.com/AlexanderLindholt/SignalPlus) at `ReplicatedStorage.scr.Library.Signal`, or adjust the source's `require` path.

## Storage access errors or delayed readiness

Check that the test Experience is published and **Enable Studio Access to API Services** is enabled in Studio. Inspect server Output alongside `State`, `IsCritical`, and `OnError`.

## A call does not finish

`MaxRetryTime` defaults to five attempts; `nil` retries indefinitely. Numbers are rounded down, with a minimum of one attempt. Calls may yield during storage I/O and retry backoff.

## `get()` returns `false`

When reopening a StoreName, reuse the original `DataTemplate` and `MemoryTemplate` table references.

## A read or write returns `false`

Check service state, Critical state, the key's `IsGetting` and `IsSaving` flags, tombstones, and the input shape. `force=true` does not bypass local key locks or tombstones. Callbacks for `Set` and `SaveData` receive raw durable `data`; callbacks for `Save`, `SetMemory`, and `SaveMemory` receive the full wrapper.

If `Get` returns a partial wrapper, check both `data` and `memory`. Do not continue gameplay with incomplete data.

## `Set()` returns `(true, false)`

The durable save succeeded; cache publication is pending. Do not repeat the same increment or grant in a new `Set` call. Inspect `PendingMemoryPublish[key]` and Output. Publication is retried at five-second intervals until the retry deadline based on the request's expiration. Server shutdown stops the task.

## Retrying after `Set()` or `SetMemory()` fails

A failed response does not prove the change was not applied. Operation IDs inside a call do not prevent duplicate application across new API calls. `GetData` can also return unsaved MemoryStore changes, so its returned `data` alone cannot prove durable commitment.

Prefer changes with the same result when repeated, such as adding a guild member by UserId. To retry cumulative operations such as increments or grants safely, caller code must record a unique request ID and result together in durable `data` and prevent duplicate application of that ID.

## `SaveData()` returns `stale` or `uncertain`

`(false, "stale")` means the supplied wrapper is behind the durable write order. `(false, "uncertain")` means a functional retry conflicted with another durable write. Recheck the state and handle the conflict. Do not force an old snapshot over newer data or immediately repeat a non-idempotent callback.

## `Save()` succeeds but the durable value is unchanged

The 60-second condition is checked during the call, not by an autosave timer. `Save` can return `true` after MemoryStore succeeds even if the durable save fails or a stale snapshot is rejected. Use `Set` for important values and check its first result.

## Changes on another server are not visible immediately

Automatic polling normally runs at 15-second intervals and can skip intermediate states. `OnNewData` delivers the full wrapper when polling finds a `data` or `memory` difference. There is no deletion-specific signal. `SaveData` does not automatically publish to the shared cache.

A shared reservation can recover durable values and tombstones while a cache remains present. Recovery within exactly 300 seconds is not guaranteed. `GetData` reads durable storage but can preserve newer unsaved shared changes in its returned wrapper; do not treat it as a raw durable-only read.

## A slow key also stops other keys from polling

v0.0.3 schedules polls independently per key. After `Automatic memory refresh failed`, task state is cleared so a later poll can be attempted. A service-wide outage, service state, or Critical state can still affect multiple keys. Check that you did not install the older v0.0.2 module.

## `UnSync()` returns `false`

The local wrapper may be missing, another operation on the same key may be running, or shared/durable storage may have failed. A failed durable save retains the local value for retry. Stop new writes and retry release. Calling again after a successful release returns `false` because the local wrapper is gone. A `stale` result caused by newer durable data is treated as successful release, preserving the newer value.

## Data is persisted even though other server IDs remain

This is the v0.0.3 behavior. `UnSync` persists the latest `data` committed by its MemoryStore update regardless of the remaining server list. A normal release can issue a DataStore request, without adding a separate MemoryStore `GetAsync`. `onlineServers` is neither a server-liveness check nor an exclusive lock.

## `Remove()` returns `(true, false)`

The durable tombstone was recorded; shared-marker publication is pending. Inspect `PendingMemoryRemoval[key]` and Output. Publication is attempted during a limited retry period and through automatic durable checks.

## `Remove()` returns `(false, false)`

A local key lock or durable-marker failure may be involved. A failed response does not establish that the marker was not actually committed. Inspect request errors and both results together.

## A removed key cannot be reopened

In v0.0.3, `Remove` and `RemoveData` leave permanent tombstones. Ordinary `Get` and `Set` calls do not recreate the key. There is no public restore API. `data.__krossSyncRemoved` is reserved.

`RemoveMemory` removes only the cache, so it can be restored from remaining durable data. Do not run v0.0.1 servers against the same keys.

## Testing

Place the [regression script](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/Script.legacy.luau) and [multi-server script](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/MultiServerTest.server.luau) beside the module. Keep `RunTests=false` during ordinary operation or exclude the test scripts. Use a separate Experience and StoreName. See [v0.0.3 validation records](Changes-EN#validation-records) for the recorded results and limits. Live-run results are stored under the RunId key in `KrossSync_V003_MULTI_RESULTS`.

When reporting an [issue](https://github.com/NoName-wks/KrossSync/issues), include the version, reproduction steps, Output, State, and return values. Do not attach secrets or actual player data.

[Tutorial](Tutorial-EN) · [API](API-EN) · [v0.0.3 changes](Changes-EN)
