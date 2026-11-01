# API reference

[한국어](API-KO) · [English](API-EN)

Draft documentation for v0.0.3, based on the [v0.0.3 working copy](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KrossSync.luau). The storage format and existing public return contracts are retained.

> [!NOTE]
> Methods can yield during storage I/O and backoff retries even if their names do not contain `Async`.

**On this page**

- [Return conventions](#return-conventions)
- [Data wrapper](#data-wrapper)
- [KrossSyncService](#krosssyncservice)
- [KrossSync instance](#krosssync-instance)
- [Reading](#reading)
- [Writing](#writing)
- [Removal](#removal)
- [Releasing](#releasing)
- [Signals](#signals)

## Return conventions

- `nil`: The key does not exist in the requested storage layer.
- `false`: The operation did not complete because of a request failure, service state, Critical state, or local per-key lock.
- `true`: The operation completed. This does not guarantee that a subsequent request to another storage service succeeded.

## Data wrapper

```luau
type Data<MemoryTemplate, DataTemplate> = {
    lastUpdate: number,
    dataCreateTime: number,
    memory: MemoryTemplate,
    data: DataTemplate,
    onlineServers: { string },
    dataRevision: number?,
    dataSequence: number?,
}
```

DataStore stores only `data` for ordinary values; MemoryStore stores the full wrapper. `dataRevision` is its base durable revision, and `dataSequence` tracks shared `data` changes since that revision. Do not modify storage metadata or internal fields beginning with `__krossSync`. Deleted durable keys retain a tombstone.

## KrossSyncService

### `get()`

```luau
KrossSyncService.get(
    StoreName: string,
    DataTemplate: DataTemplate,
    MemoryTemplate: MemoryTemplate,
    NormalExpirationTime: number?
) -> KrossSync | false
```

Opens a DataStore and a MemoryStoreHashMap with the same name, then caches an instance by StoreName. `NormalExpirationTime` defaults to 600 seconds.

Calling again with the same StoreName returns the existing instance, but returns `false` if either template table **reference** differs from the original.

### `KrossSyncs`

```luau
KrossSyncService.KrossSyncs: {[string]: KrossSync}
```

Cached instances indexed by StoreName. Do not modify this table directly.

### `State`

```luau
KrossSyncService.State = {
    Total: "NotReady" | "NoInternet" | "NoAccess" | "Access" | "Error",
    Data: "NotReady" | "NoInternet" | "NoAccess" | "Access" | "Error",
    Memory: "NotReady" | "NoInternet" | "NoAccess" | "Access" | "Error",
}
```

| State | Meaning |
| --- | --- |
| `NotReady` | Initial storage-access checks are pending |
| `Access` | Internal requests are allowed |
| `NoInternet` | A startup storage-access check failed |
| `NoAccess` | DataStore request budget is considered insufficient |
| `Error` | Repeated errors activated Critical state |

`Access` does not guarantee that later individual requests will succeed.

### `IsCritical`

```luau
KrossSyncService.IsCritical = {
    Total: boolean,
    Data: boolean,
    Memory: boolean,
}
```

Indicates Critical state activated by repeated storage errors.

## KrossSync instance

| Field | Type | Description |
| --- | --- | --- |
| `MaxRetryTime` | `number?` | Maximum attempts. Defaults to `5`; `nil` retries indefinitely. Numbers are rounded down, with a minimum of one attempt. |
| `ExpirationTime` | `number` | MemoryStore TTL, default 600 seconds. |
| `LastData` | `{[string]: Data}` | Local wrapper cache by key. |
| `RemovedKeys` | `{[string]: number}` | Expiration times of locally known tombstones. |
| `PendingDataSave` | `{[string]: boolean}` | Background durable-save retry state. |
| `PendingMemoryPublish` | `{[string]: {revision: number}}` | Pending publication of committed durable revisions. |
| `PendingMemoryRemoval` | `{[string]: table}` | Pending publication of shared tombstones. |
| `IsGetting` | `{[string]: boolean}` | Local reads in progress by key. |
| `IsSaving` | `{[string]: boolean}` | Local writes in progress by key. |
| `DataTemplate` | `table` | Default durable-data template. |
| `MemoryTemplate` | `table` | Default temporary-state template. |

`Store`, `Map`, and `MapName` are also exposed. Modifying raw storage while KrossSync is active can make caches and cross-server state inconsistent.

## Reading

### `Get()`

```luau
KrossSync:Get(key: string, force: boolean)
    -> Data | false, { Data: boolean, Memory: boolean }?
```

Reads MemoryStore first, then restores from DataStore if needed. If neither service contains the key, it persists template `data` through `SaveData` before creating the full MemoryStore wrapper. Loading a new key therefore consumes durable write requests; this is not a read-only existence check.

If durable creation succeeds but the shared write fails, it can return a partial wrapper with `memory=nil` and `{Data=true, Memory=false}`. The second status table is not returned on every path.

`force=true` bypasses service-state and Critical checks, but not `IsGetting` or `IsSaving` locks for the same key.

### `GetData()`

```luau
KrossSync:GetData(key: string, force: boolean)
    -> Data | nil | false
```

Reads raw durable data and its revision, checks removal markers, and combines the result with the shared wrapper. Returns `nil` for a missing key and `false` for removal or a request/synchronization failure. Newer unsaved MemoryStore changes can be preserved, so the returned `data` is not necessarily identical to the durable value. This method can update caches and restore MemoryStore.

Its return value alone cannot establish whether a particular write was durably committed. Do not use it as proof when deciding whether to repeat a failed increment or grant in a new call. Safe retries require caller-owned request IDs and results to be recorded together in durable `data`, with duplicate application of the same ID prevented.

### `GetMemory()`

```luau
KrossSync:GetMemory(key: string, force: boolean)
    -> Data | nil | false
```

Reads the full MemoryStore wrapper. If the current `game.JobId` is missing or the server list needs normalization, an `UpdateAsync` rereads the latest value and registers the current server once. An active tombstone discards the local cache and returns `false`.

## Writing

### `Set()`

```luau
KrossSync:Set(
    key: string,
    update: Data | ((old: DataTemplate?) -> DataTemplate?),
    expiration: number?,
    force: boolean?
) -> (dataSaved: boolean, memorySaved: boolean)
```

Commits through DataStore `UpdateAsync` first, then publishes the committed revision to MemoryStore. A table supplies the full wrapper's `.data`; a callback receives the existing raw durable `data`.

`(true, false)` means the durable save completed but cache publication is pending. Retransmission is attempted at five-second intervals for `expiration` or `ExpirationTime`. Server shutdown can stop the task. It does not overwrite a newer revision, and publication after `UnSync` does not resubscribe the key.

`(false, false)` includes request failure, removal, stale wrappers, concurrent-write conflicts, and local locks. A failed response does not prove that the write was not applied. Immediately repeating a non-idempotent change in a new call can apply it twice.

### `SetMemory()`

```luau
KrossSync:SetMemory(
    key: string,
    update: Data | ((old: Data?) -> Data?),
    expiration: number?,
    force: boolean?
) -> boolean
```

Updates the shared cache using the same full-wrapper input as `SaveMemory`. Ordinary updates do not read DataStore; a missing shared entry triggers durable-state and removal checks before recovery. `true` means the MemoryStore write succeeded, not that data is persisted or every server has received it. If it returns `false`, inspect the state before deciding how to retry.

### `Save()`

```luau
KrossSync:Save(
    key: string,
    data: Data | ((old: Data?) -> Data?),
    expiration: number,
    force: boolean
) -> boolean
```

The general save entry point. If less than 60 seconds have passed relative to `dataCreateTime`, it updates only MemoryStore. At 60 seconds or more, it updates MemoryStore first and then saves the committed `data` to DataStore. The condition is checked only when `Save()` is called; it is not a background autosave timer.

If MemoryStore succeeds but the durable save fails, `Save` can report logical success with `true` to avoid replaying a functional callback and retry the latest local value in the background. Consequently, `true` does not always mean immediate durable persistence.

Functional input receives the latest full wrapper. The callback may run repeatedly during `UpdateAsync` conflict handling, so keep it free of external side effects.

### `SaveData()`

```luau
KrossSync:SaveData(
    key: string,
    data: Data | ((old: DataTemplate?) -> DataTemplate?),
    force: boolean
) -> boolean, ("stale" | "uncertain")?
```

Both table and callback inputs use `UpdateAsync`. A table supplies the full wrapper's `.data` and write-order information; a stale snapshot returns `(false, "stale")`. A callback receives raw existing DataStore data and can return `nil` to cancel. A functional retry that conflicts with another durable write can return `(false, "uncertain")`. Tombstones are checked inside the same durable-key update callback. It does not automatically publish to MemoryStore; use `Set` when both persistence and sharing are needed.

### `SaveMemory()`

```luau
KrossSync:SaveMemory(
    key: string,
    data: Data | ((old: Data?) -> Data?),
    expiration: number,
    force: boolean
) -> boolean
```

Stores the full wrapper through `UpdateAsync` for both table and callback inputs. Tables are deeply copied and combined with the latest `onlineServers` list. Callbacks receive the latest full wrapper. Ordinary writes cannot overwrite active tombstones.

Changes to shared `data` increment its sequence, and stale table inputs are rejected. Keep functional callbacks free of external side effects. Request identifiers protect internal retries of a single call, not duplicate application across new calls.

## Removal

### `Remove()`

```luau
KrossSync:Remove(key: string) -> (dataRemoved: boolean, memoryRemoved: boolean)
```

Commits a permanent tombstone to DataStore before publishing one to MemoryStore. The shared tombstone TTL is the greater of `ExpirationTime` and 60 seconds. Ordinary `Get` and `Set` calls do not recreate a durably removed key. `data.__krossSyncRemoved` is reserved.

The first result reports durable-marker success; the second reports shared-marker success. For `(true, false)`, shared-marker publication is retried at five-second intervals for a period equal to the shared TTL. A local read/write in progress or failed durable-marker write returns `(false, false)`.

### `RemoveData()`

```luau
KrossSync:RemoveData(key: string) -> boolean
```

Writes a permanent tombstone to DataStore and clears the local cache. It does not immediately publish to MemoryStore. Prefer `Remove` for ordinary permanent removal.

### `RemoveMemory()`

```luau
KrossSync:RemoveMemory(key: string) -> boolean
```

A low-level method that removes the MemoryStore entry and local cache only. If durable data remains, a later `Get` can restore the wrapper.

## Releasing

### `UnSync()`

```luau
KrossSync:UnSync(key: string) -> boolean
```

Removes the current JobId through MemoryStore `UpdateAsync`, persists the `data` from the latest wrapper committed by that request, and releases local synchronization. v0.0.3 attempts the save even if other server IDs remain. It uses neither an old local snapshot nor a separate MemoryStore `GetAsync`.

If `SaveData` returns `stale` because a newer durable value exists, it preserves that value, releases the key, and returns `true`. An ordinary durable-save failure retains the local wrapper for retry and returns `false`. Stop writes before releasing and retry failed releases with `UnSync`. A missing local wrapper returns `false`; discovering a tombstone during release can clear the cache and return `true`.

Each ordinary release path can issue a DataStore `UpdateAsync` request. Identical snapshots can cancel the write, but request cost still matters. `true` does not mean every server has stopped using the key or every temporary change has been persisted.

## Signals

### Service signals

```luau
KrossSyncService.OnCriticalToggle:Connect(function(totalCritical, detail)
    -- detail.Total, detail.Data, detail.Memory
end)

KrossSyncService.OnError:Connect(function(position, message, storeName, key, input)
    -- position: 1 = DataStore, 2 = MemoryStore
end)
```

`OnError` fires for failed reads, writes, removals, and tombstone checks after their final attempt. `position=1` identifies DataStore; `position=2` identifies MemoryStore. Some internal checks omit the final `input` argument.

### Instance signals

```luau
KrossSync.OnNewData:Connect(function(latestWrapper)
end)

KrossSync.OnGettingToggle:Connect(function(isGetting)
end)

KrossSync.OnSavingToggle:Connect(function(isSaving)
end)
```

`OnNewData` fires when automatic polling detects a `data` or `memory` difference. It is not an event per intermediate write and has no deletion-specific notification. None of these three signals includes the changed key.

> [!WARNING]
> `RemoveData` and `RemoveMemory` are low-level APIs that do not synchronize the other storage layer. Prefer `Remove` for permanent user-data removal.

Next: [Tutorial](Tutorial-EN) · [Troubleshooting](Troubleshooting-EN) · [v0.0.3 changes](Changes-EN)
