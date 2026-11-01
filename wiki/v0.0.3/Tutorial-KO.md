# 튜토리얼

[한국어](Tutorial-KO) · [English](Tutorial-EN)

KrossSync를 Roblox 서버에 설치하고, 길드 데이터를 열고 저장한 뒤 해제하는 기본 흐름을 설명합니다.

**이 페이지에서**

- [요구 사항](#요구-사항)
- [설치](#설치)
- [저장소 만들기](#저장소-만들기)
- [저장소 준비 기다리기](#저장소-준비-기다리기)
- [길드 생성과 가입](#길드-생성과-가입)
- [길드 공지 공유와 해제](#길드-공지-공유와-해제)
- [데이터 수명 주기](#데이터-수명-주기)
- [길드 삭제](#길드-삭제)
- [운영 전 체크리스트](#운영-전-체크리스트)

> [!CAUTION]
> 이 튜토리얼은 v0.0.3 작업본 기준의 준비 문서입니다. 운영 데이터와 분리된 Experience와 StoreName으로 먼저 검증하세요.

## 요구 사항

- 서버에서 실행되는 `Script` 또는 서버 전용 `ModuleScript`
- Roblox `DataStoreService`와 `MemoryStoreService`
- [Signal+](https://github.com/AlexanderLindholt/SignalPlus)(v3.x.x)(Made by AlexanderLindholt)
- 게시된 테스트 Experience

## 설치

1. [`source/NEXT VERSION/V0.0.3/KrossSync.luau`](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KrossSync.luau) 또는 [한국어 주석 버전](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KR/KrossSync_KR.luau)을 서버 전용 `ModuleScript`로 추가합니다.
2. ModuleScript 이름을 `KrossSync`로 지정합니다.
3. [Signal+](https://github.com/AlexanderLindholt/SignalPlus)(v3.x.x)(Made by AlexanderLindholt)를 `signal`변수에 `require()`합니다. 기본 경로는 `ReplicatedStorage.scr.Library.Signal`이며, 다른 위치를 사용한다면 KrossSync 소스의 `require` 경로를 수정합니다.
4. Studio에서는 **Game Settings → Security → Enable Studio Access to API Services**를 켭니다.
5. 운영 배포에서는 회귀·다중 서버 Script와 `Tests` 폴더를 제외합니다. 유지한다면 테스트 Script를 비활성화하고 `RunTests=false`를 확인합니다.

> [!WARNING]
> Studio의 API Services를 활성화하면 실제 DataStore에 접근할 수 있습니다. 테스트 전용 Experience와 StoreName을 권장합니다.

## 저장소 만들기

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

KrossSync는 `StoreName`별 객체를 캐시합니다. 같은 이름으로 `get`을 다시 호출할 때는 내용만 같은 새 table이 아니라 `DATA_TEMPLATE`과 `MEMORY_TEMPLATE`의 기존 참조를 재사용해야 합니다.

`MaxRetryTime`은 이름과 달리 시간이 아니라 최대 시도 횟수로 사용됩니다. 기본값은 `5`이며 `nil`은 성공할 때까지 재시도합니다. 숫자는 내림한 뒤 최소 1회로 보정됩니다.

## 저장소 준비 기다리기

```luau
local deadline = os.clock() + 30

while KrossSyncService.State.Total == "NotReady" and os.clock() < deadline do
    task.wait(0.25)
end

if KrossSyncService.State.Total ~= "Access" then
    error(`KrossSync storage unavailable: {KrossSyncService.State.Total}`)
end
```

`State.Total`이 `Access`가 되기 전에 일반 `Get`이나 `Save`를 호출하면 `false`가 반환될 수 있습니다.

## 길드 생성과 가입

같은 길드 ID를 사용하는 서버들은 하나의 키를 공유합니다. 아래는 서버에서 호출하는 저장 예시입니다. 실제 가입 요청의 인증·초대·정원 정책은 서버 게임 코드에서 처리하세요. 예시 사용자 ID는 프로젝트 값으로 바꿉니다.

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

`Get`은 두 저장소에 키가 없으면 템플릿 `data`를 DataStore에 먼저 저장하고 공유 래퍼를 만듭니다. 존재 확인만 하는 순수 조회로 취급하지 마세요.

새 길드는 이름·길드장·멤버를 영구 저장합니다. 길드 ID는 생성 요청에서 한 번 정하고 여러 서버가 같은 ID를 재사용해야 합니다.

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

가입은 최신 영구 멤버 목록에 사용자를 추가합니다. 문자열 UserId를 키로 사용하고 같은 사용자를 다시 추가해도 한 항목만 유지합니다.

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

`Set`의 함수 입력은 전체 래퍼가 아니라 현재 영구 `data`입니다. 저장 중 콜백이 반복될 수 있으므로 보상 지급이나 RemoteEvent 발송은 콜백 안에서 하지 마세요. `guild`는 처음 조회한 스냅샷이므로 이후 멤버 판정에 그대로 재사용하지 마세요.

## 길드 공지 공유와 해제

여기서 공지는 임시 공유 상태입니다. 만료 뒤에도 유지해야 하는 공지는 `data`에 넣고 `Set`으로 저장하세요.

```luau
local shared = GuildStore:SetMemory(key, function(current)
    current.memory.notice = "길드 레이드는 20시에 시작합니다."
    return current
end)

if not shared then
    warn("Guild notice publication failed")
end
```

다른 서버는 같은 키를 `Get`으로 열고 자동 조회가 발견한 변경을 받아 UI를 갱신할 수 있습니다. 아래 신호 연결은 StoreName별로 한 번만 등록하세요.

```luau
GuildStore.OnNewData:Connect(function(latest)
    print("Guild:", latest.data.name)
    print("Notice:", latest.memory.notice)
end)
```

신호는 변경된 키를 전달하지 않으므로 이 예시는 해당 저장소에서 한 길드만 구독한다고 가정합니다. 중간 공지는 생략될 수 있습니다.

서버에서 해당 길드를 사용하는 모든 작업을 끝낸 뒤 해제합니다. 같은 서버의 여러 플레이어가 길드를 공유하면 한 플레이어가 나갈 때마다 해제하지 마세요. v0.0.3은 다른 서버가 길드를 사용 중이어도 공유 갱신이 확정한 최신 `data`의 영구 저장을 시도합니다. `memory.notice`는 영구 저장하지 않습니다.

```luau
if not GuildStore:UnSync(key) then
    warn("Guild synchronization did not close")
end
```

## 데이터 수명 주기

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

DataStore에는 `data`만 저장되고 MemoryStore에는 전체 래퍼가 저장됩니다.

```text
Get
 ├─ MemoryStore hit → 현재 JobId 등록 → 래퍼 반환
 └─ MemoryStore miss
     ├─ DataStore hit → MemoryStore 복구 → 래퍼 반환
     └─ DataStore miss → 템플릿 data 영구 저장 → 공유 래퍼 생성

Set
 ├─ DataStore에 data와 버전 확정
 └─ 확정된 버전을 MemoryStore에 게시
     └─ 게시만 실패 → 제한된 기간 동안 재전달

SetMemory
 └─ 최신 전체 래퍼를 MemoryStore에 갱신

Save
 ├─ dataCreateTime 기준 60초 미만 → MemoryStore 갱신
 └─ 60초 이상 → MemoryStore 갱신 후 DataStore 저장
     └─ DataStore만 실패 → 최신 값을 백그라운드에서 재시도

UnSync
 ├─ 현재 JobId 제거
 ├─ 다른 서버 ID가 남아 있어도 최신 공유 data 영구 저장 시도
 ├─ 더 최신인 영구 값이 있음 → 덮어쓰지 않고 해제
 └─ 저장 실패 → 재시도용 로컬 래퍼 유지

Remove
 ├─ DataStore에 영구 삭제 표식 확정
 └─ MemoryStore에 공유 삭제 표식 게시
     └─ 게시만 실패 → 제한된 기간 동안 재게시
```

`UnSync`가 `false`이면 영구 저장 실패 등의 원인을 확인한 뒤 같은 키의 해제를 재시도합니다. 다른 서버 ID가 남아 있다는 이유로 저장을 생략하지 않지만, 모든 서버가 저장 전에 갑자기 종료되는 상황까지 보호하지는 않습니다.

60초 조건은 `Save()` 호출 시에만 검사됩니다. 활성 키는 기본 15초 간격으로 MemoryStore를 확인하고 `data` 또는 `memory` 변경을 발견하면 `OnNewData`에 전체 래퍼를 전달합니다. 키별 조회 작업은 독립적이므로 한 키의 느린 요청이 다른 키의 다음 조회를 기다리게 하지 않습니다. 중간 변경은 생략될 수 있습니다. 키별 300초 간격의 공유 검증 예약으로 영구 값·삭제 표식도 확인하지만 정확한 복구 시간은 보장하지 않습니다.

> [!IMPORTANT]
> `onlineServers`는 배타적 세션 락이 아닙니다. 오래된 `SaveData` 래퍼는 거부되며 자동 병합하지 않습니다. 실패한 증가·지급을 새 호출로 즉시 반복하지 마세요. 처음 조회한 길드의 오래된 래퍼를 수정해 다시 저장하기보다 함수형 갱신을 사용하세요.

## 길드 삭제

길드 해산이 서버에서 승인되고 새 가입·저장 작업을 멈춘 뒤 `Remove`를 사용합니다. DataStore에 만료되지 않는 삭제 표식을 먼저 기록한 뒤 MemoryStore에도 표식을 게시합니다.

```luau
local dataRemoved, memoryRemoved = GuildStore:Remove(key)

if not dataRemoved then
    warn(`Durable removal did not complete: {key}`)
elseif not memoryRemoved then
    warn(`Removal cache publication is pending: {key}`)
end
```

`Remove`가 `(false, false)`를 반환하면 같은 키에서 읽기나 쓰기가 진행 중일 수 있습니다. 진행 중인 작업이 끝난 뒤 다시 호출하세요.

> [!WARNING]
> `RemoveData`도 영구 삭제 표식을 남기지만 공유 캐시를 즉시 삭제 상태로 바꾸지는 않습니다. `RemoveMemory`는 공유 캐시만 지우므로 영구 값이 남으면 복구됩니다. 삭제된 키는 일반 `Get`·`Set`으로 재생성되지 않습니다. 최상위 `data.__krossSyncRemoved`는 예약 필드입니다.

## 운영 전 체크리스트

1. `State.Total == "Access"`인지 확인합니다.
2. 항상 `Get`으로 키를 연 뒤 값을 변경합니다.
3. `Get`의 부분 성공 가능성을 고려해 `data`와 `memory`를 모두 검사합니다.
4. 중요한 변경은 `Set`, 임시 상태는 `SetMemory`를 사용하고 반환값을 확인합니다.
5. 키 사용이 끝나면 새 쓰기를 멈추고 `UnSync`를 호출합니다.
6. 키를 영구 삭제할 때는 `Remove`의 두 반환값을 모두 확인합니다.
7. 일반 코드에서는 `force=true`를 사용하지 않습니다.
8. 함수형 저장 콜백은 `UpdateAsync`에서 여러 번 실행될 수 있으므로 외부 상태를 변경하지 않게 작성합니다.
9. 서로 다른 버전의 서버를 같은 저장소·키에 혼합 운영하는 호환성은 별도로 검증합니다. 테스트 Script는 `RunTests=false`로 둡니다.

다음: [API](API-KO) · [문제 해결](Troubleshooting-KO) · [v0.0.3 변경점](Changes-KO)
