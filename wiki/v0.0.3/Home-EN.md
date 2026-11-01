# KrossSync v0.0.3

[한국어](Home-KO) · [English](Home-EN)

**Manage persistent data and shared state across Roblox servers through one Luau API.**

![Luau](https://img.shields.io/badge/language-Luau-00A2FF)
![version](https://img.shields.io/badge/version-v0.0.3-orange)
![license](https://img.shields.io/badge/license-MIT-blue)

[Tutorial](Tutorial-EN) · [API](API-EN) · [Changes](Changes-EN) · [Troubleshooting](Troubleshooting-EN)

> Local documentation draft for the v0.0.3 alpha working copy at `source/NEXT VERSION/V0.0.3/KrossSync.luau`.

KrossSync is a server-only module. DataStore holds persistent `data`; MemoryStore shares the full wrapper, including temporary `memory`, server IDs, and version information. `Set` and `SetMemory` share the latest state. Intermediate changes may be skipped.

## What changed in v0.0.3

- Automatic polling is scheduled independently for each key, so a slow key does not hold up the next poll of another key.
- Polling exceptions clear the task state, allowing another poll to be attempted.
- `UnSync` attempts to persist the latest shared `data` even when other server IDs remain.
- A failed durable save retains the local wrapper for retry. A newer durable value is preserved and the key is released.
- The 15-second polling interval, 300-second shared durable-check interval, storage format, and existing API return contracts remain unchanged. MessagingService is not included.

## Getting started

1. Install either the [English source](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KrossSync.luau) or the [Korean source](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KR/KrossSync_KR.luau) as a server-only ModuleScript.
2. `require()` [Signal+](https://github.com/AlexanderLindholt/SignalPlus)(v3.x.x)(Made by AlexanderLindholt) into the `signal` variable. Its default path is `ReplicatedStorage.scr.Library.Signal`.
3. Follow the [guild tutorial](Tutorial-EN) to create a guild, add members, share a notice, and release the key.

The existing `source/KrossSync.luau` is v0.0.2. Exclude regression scripts, multi-server test scripts, and the `Tests` folder from production deployment.

## Choosing a write method

| Purpose | API | Meaning of success |
| --- | --- | --- |
| Persist and share important guild data | `Set` | Check `(dataSaved, memorySaved)` for the two storage services |
| Share temporary state such as a notice | `SetMemory` | MemoryStore write succeeded |
| Update shared state with conditional persistence | `Save` | Does not always mean a durable save completed |
| Stop using a key | `UnSync` | Release after saving the latest shared `data`, or preserving a newer durable value |
| Permanently remove a guild | `Remove` | Both durable and shared removal markers were written |

Each `UnSync` can issue a DataStore request. Save important changes with `Set` when they happen. `memory` is not persisted.

## Validation and limits

Existing local records include 70 mock checks, focused checks against actual storage services, and the two-live-server normal-shutdown run `V3N_0925634e499e` on 2026-10-18. See [validation records](Changes-EN#validation-records) for their scope. These tests were not rerun while writing this documentation.

Actual abrupt server termination, real post-commit response loss, production-scale load, and long-term stability remain unverified. Updates across the two storage services are not atomic. MemoryStore-only changes may be lost if every related server stops before persistence. `onlineServers` is neither an exclusive lock nor proof that a server is alive.

[GitHub repository](https://github.com/NoName-wks/KrossSync) · [KrossSync MIT License](https://github.com/NoName-wks/KrossSync/blob/448d5dd307a9ccba75899eb5d832506c6d539f60/LICENSE)
