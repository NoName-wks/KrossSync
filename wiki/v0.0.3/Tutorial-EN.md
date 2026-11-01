# Tutorial

[한국어](Tutorial-KO) · [English](Tutorial-EN)

Install KrossSync on the Roblox server, then load, update, and release guild data.

**On this page**

- [Requirements](#requirements)
- [Installation](#installation)
- [Creating a store](#creating-a-store)
- [Waiting for storage readiness](#waiting-for-storage-readiness)
- [Creating a guild and adding members](#creating-a-guild-and-adding-members)
- [Sharing a notice and releasing the guild](#sharing-a-notice-and-releasing-the-guild)
- [Data lifecycle](#data-lifecycle)
- [Deleting a guild](#deleting-a-guild)
- [Before production use](#before-production-use)

> [!CAUTION]
> This is draft documentation for the v0.0.3 working copy. Validate it in an Experience and StoreName separate from production data.

## Requirements

- A server Script or server-only ModuleScript
- Roblox `DataStoreService` and `MemoryStoreService`
- [Signal+](https://github.com/AlexanderLindholt/SignalPlus)(v3.x.x)(Made by AlexanderLindholt)
- A published test Experience

## Installation

1. Add [`source/NEXT VERSION/V0.0.3/KrossSync.luau`](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KrossSync.luau) or the [Korean source](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KR/KrossSync_KR.luau) as a server-only ModuleScript.
2. Name the ModuleScript `KrossSync`.
3. `require()` [Signal+](https://github.com/AlexanderLindholt/SignalPlus)(v3.x.x)(Made by AlexanderLindholt) into the `signal` variable. The default path is `ReplicatedStorage.scr.Library.Signal`. Update the module's `require` path if you install it elsewhere.
4. In Studio, enable **Game Settings → Security → Enable Studio Access to API Services**.
5. Exclude regression scripts, multi-server scripts, and `Tests` from production deployment. If retained, disable the scripts and check `RunTests=false`.

> [!WARNING]
> Enabling Studio API Services gives Studio access to actual DataStore data. Use a separate test Experience and StoreName.

## Creating a store

```luau
local KrossSyncService = require(script.Parent:WaitForChild("KrossSync"))

local DATA_TEMPLATE = {
    name = "",
    ownerUserId = 0,
    members = {},
}

local MEMORY_TEMPLATE = {
    notice = "",
}

local GuildStore = KrossSyncService.get(
    "GuildDataV003",
    DATA_TEMPLATE,
    MEMORY_TEMPLATE,
    600
)

assert(GuildStore, "Guild store already uses different template tables")
GuildStore.MaxRetryTime = 5
```

KrossSync caches instances by `StoreName`. Reuse the original `DATA_TEMPLATE` and `MEMORY_TEMPLATE` table references when reopening the same name. New tables with identical contents are still different references.

Despite its name, `MaxRetryTime` is a maximum attempt count. It defaults to `5`; `nil` retries until success. Numeric values are rounded down, with a minimum of one attempt.

## Waiting for storage readiness

```luau
local deadline = os.clock() + 30

while KrossSyncService.State.Total == "NotReady" and os.clock() < deadline do
    task.wait(0.25)
end

if KrossSyncService.State.Total ~= "Access" then
    error(`KrossSync storage unavailable: {KrossSyncService.State.Total}`)
end
```

Ordinary `Get` or `Save` calls may return `false` before `State.Total` becomes `Access`.

## Creating a guild and adding members

Servers that use the same guild ID share one key. These examples run on the server. Authentication, invitation rules, and member limits belong in your server game code. Replace the example user IDs with your project values.

```luau
local guildId = "guild-demo-001"
local key = `guild:{guildId}`
local ownerUserId = 123_456
local memberUserId = 234_567

local guild = GuildStore:Get(key, false)
if guild == false or guild.data == nil or guild.memory == nil then
    if guild ~= false then
        GuildStore:UnSync(key)
    end
    error("Guild load failed")
end
```

If the key is absent from both services, `Get` first persists template `data` to DataStore and then creates the shared wrapper. It is not a read-only existence check.

Create a guild by persisting its name, owner, and members. Assign the guild ID once per creation request and reuse it across servers.

```luau
if guild.data.ownerUserId == 0 then
    local dataSaved, memorySaved = GuildStore:Set(key, function(current)
        if current and current.ownerUserId ~= 0 then
            return nil
        end
        return {
            name = "Kross Knights",
            ownerUserId = ownerUserId,
            members = {
                [tostring(ownerUserId)] = "owner",
            },
        }
    end)

    if not dataSaved then
        warn("Guild creation failed or was cancelled; check current state")
    elseif not memorySaved then
        warn("Guild created; cache publication is pending")
    end
end
```

Add a member to the latest durable member list. String UserIds are used as keys, so adding the same member again keeps a single entry.

```luau
local dataSaved, memorySaved = GuildStore:Set(key, function(current)
    if not current or current.ownerUserId == 0 then
        return nil
    end
    local userKey = tostring(memberUserId)
    if current.members[userKey] == nil then
        current.members[userKey] = "member"
    end
    return current
end)

if not dataSaved then
    warn("Guild join result uncertain; check membership before retrying")
elseif not memorySaved then
    warn("Member saved; cache publication is pending")
end
```

The `Set` callback receives raw durable `data`, not the full wrapper. A callback may run repeatedly: do not grant rewards or fire RemoteEvents inside it. `guild` is the initial snapshot; do not reuse it for later membership decisions.

## Sharing a notice and releasing the guild

The notice below is temporary shared state. If it must survive expiration, store it in `data` with `Set`.

```luau
local shared = GuildStore:SetMemory(key, function(current)
    current.memory.notice = "The guild raid starts at 20:00."
    return current
end)

if not shared then
    warn("Guild notice publication failed")
end
```

Another server can open the same key with `Get` and update its UI when automatic polling detects a change. Register this connection once per StoreName.

```luau
GuildStore.OnNewData:Connect(function(latest)
    print("Guild:", latest.data.name)
    print("Notice:", latest.memory.notice)
end)
```

The signal does not include the changed key. This example therefore assumes only one guild is subscribed in this store. Intermediate notices may be skipped.

Release the key after every task using that guild on the server has finished. If several players on the same server share the guild, do not release it whenever one player leaves. In v0.0.3, release attempts to persist the latest `data` committed by the shared update even while other servers still use the guild. `memory.notice` is not persisted.

```luau
if not GuildStore:UnSync(key) then
    warn("Guild synchronization did not close")
end
```

## Data lifecycle

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

DataStore holds `data`; MemoryStore holds the full wrapper.

```text
Get
 ├─ MemoryStore hit → register current JobId → return wrapper
 └─ MemoryStore miss
     ├─ DataStore hit → restore MemoryStore → return wrapper
     └─ DataStore miss → persist template data → create shared wrapper

Set
 ├─ Commit data and version to DataStore
 └─ Publish the committed version to MemoryStore
     └─ Publication fails → retry for a limited period

SetMemory
 └─ Update the latest full wrapper in MemoryStore

Save
 ├─ Less than 60 seconds since dataCreateTime → update MemoryStore
 └─ 60 seconds or more → update MemoryStore, then save DataStore
     └─ Only DataStore fails → retry the latest local value in the background

UnSync
 ├─ Remove the current JobId
 ├─ Attempt to persist latest shared data even if other server IDs remain
 ├─ Newer durable value exists → preserve it and release
 └─ Save fails → retain the local wrapper for retry

Remove
 ├─ Commit a permanent tombstone to DataStore
 └─ Publish a shared tombstone to MemoryStore
     └─ Publication fails → retry for a limited period
```

If `UnSync` returns `false`, inspect the cause, such as a durable-save failure, then retry release for the same key. Other server IDs no longer cause release persistence to be skipped, but this does not protect against every server stopping before persistence.

The 60-second condition is checked only when `Save()` is called. Active keys normally poll MemoryStore at 15-second intervals. When polling detects a `data` or `memory` change, `OnNewData` delivers the full wrapper. Keys are scheduled independently, so a slow key does not hold up the next poll of another key. Intermediate changes may be skipped. A shared reservation checks durable values and tombstones at a 300-second interval per key; exact recovery time is not guaranteed.

> [!IMPORTANT]
> `onlineServers` is not an exclusive session lock. Stale `SaveData` wrappers are rejected without automatic merging. Do not immediately repeat a failed increment or grant in a new call. Prefer functional updates over editing and resaving an old guild snapshot.

## Deleting a guild

After server code authorizes disbanding the guild and stops new joins and writes, call `Remove`. It commits a permanent tombstone to DataStore before publishing a shared tombstone to MemoryStore.

```luau
local dataRemoved, memoryRemoved = GuildStore:Remove(key)

if not dataRemoved then
    warn(`Durable removal did not complete: {key}`)
elseif not memoryRemoved then
    warn(`Removal cache publication is pending: {key}`)
end
```

If `Remove` returns `(false, false)`, a read or write for the same key may still be running. Retry once the in-progress operation has finished.

> [!WARNING]
> `RemoveData` also writes a permanent tombstone but does not immediately mark the shared cache as removed. `RemoveMemory` removes only the shared cache, which can be restored if durable data remains. Ordinary `Get` and `Set` calls do not recreate deleted keys. The top-level `data.__krossSyncRemoved` field is reserved.

## Before production use

1. Check `State.Total == "Access"`.
2. Open the key with `Get` before changing it.
3. Check both `data` and `memory` because `Get` can partially succeed.
4. Use `Set` for important data and `SetMemory` for temporary state; check return values.
5. Stop new writes and call `UnSync` when the key is no longer needed.
6. Check both return values of `Remove`.
7. Avoid `force=true` in ordinary game code.
8. Keep functional write callbacks free of external side effects because `UpdateAsync` may execute them repeatedly.
9. Validate mixed-version servers separately when they share stores and keys. Keep test scripts at `RunTests=false`.

Next: [API](API-EN) · [Troubleshooting](Troubleshooting-EN) · [v0.0.3 changes](Changes-EN)
