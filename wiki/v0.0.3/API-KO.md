# API 레퍼런스

[한국어](API-KO) · [English](API-EN)

v0.0.3 준비 문서입니다. 기준은 [v0.0.3 작업본](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KrossSync.luau)이며 저장 형식과 기존 공개 메서드의 반환 계약을 유지합니다.

> [!NOTE]
> 메서드 이름에 `Async`가 없어도 DataStore·MemoryStore I/O와 백오프 재시도 중 yield할 수 있습니다.

**이 페이지에서**

- [반환값 규칙](#반환값-규칙)
- [Data 래퍼](#data-래퍼)
- [KrossSyncService](#krosssyncservice)
- [KrossSync 객체](#krosssync-객체)
- [읽기](#읽기)
- [저장](#저장)
- [삭제](#삭제)
- [해제](#해제)
- [신호](#신호)

## 반환값 규칙

- `nil`: 요청한 저장 계층에 키가 없습니다.
- `false`: 요청 실패, 서비스 상태, 치명 오류 또는 키별 진행 잠금 때문에 작업이 완료되지 않았습니다.
- `true`: 해당 작업이 완료되었습니다. 이후의 별도 저장소 요청 성공까지 보장하는 값은 아닙니다.

## Data 래퍼

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

DataStore의 일반 값에는 `data`만 저장되고 MemoryStore에는 전체 래퍼가 저장됩니다. `dataRevision`은 기준 영구 버전, `dataSequence`는 해당 버전 이후 공유 `data`의 변경 순서입니다. 저장소 메타데이터와 `__krossSync`로 시작하는 내부 필드는 직접 수정하지 마세요. 삭제된 영구 키에는 삭제 표식이 남습니다.

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

같은 이름의 DataStore와 MemoryStoreHashMap을 열고 StoreName별 KrossSync 객체를 캐시합니다. `NormalExpirationTime`의 기본값은 600초입니다.

같은 StoreName으로 다시 호출하면 기존 객체를 반환하지만, 템플릿 table의 **참조**가 최초 호출과 다르면 `false`를 반환합니다.

### `KrossSyncs`

```luau
KrossSyncService.KrossSyncs: {[string]: KrossSync}
```

StoreName별로 캐시된 객체입니다. 직접 수정하지 마세요.

### `State`

```luau
KrossSyncService.State = {
    Total: "NotReady" | "NoInternet" | "NoAccess" | "Access" | "Error",
    Data: "NotReady" | "NoInternet" | "NoAccess" | "Access" | "Error",
    Memory: "NotReady" | "NoInternet" | "NoAccess" | "Access" | "Error",
}
```

| 상태 | 의미 |
| --- | --- |
| `NotReady` | 초기 저장소 접근 확인 중 |
| `Access` | 내부 요청을 허용하는 상태 |
| `NoInternet` | 시작 시 저장소 접근 확인 실패 |
| `NoAccess` | DataStore 요청 예산 부족으로 판단됨 |
| `Error` | 반복 오류로 치명 상태가 활성화됨 |

`Access`는 이후의 개별 저장소 요청 성공을 보장하지 않습니다.

### `IsCritical`

```luau
KrossSyncService.IsCritical = {
    Total: boolean,
    Data: boolean,
    Memory: boolean,
}
```

반복 저장 오류로 활성화된 치명 상태를 나타냅니다.

## KrossSync 객체

| 필드 | 형식 | 설명 |
| --- | --- | --- |
| `MaxRetryTime` | `number?` | 최대 시도 횟수. 기본값은 `5`이고 `nil`이면 무한 시도합니다. 숫자는 내림 후 최소 1회입니다. |
| `ExpirationTime` | `number` | MemoryStore TTL. 기본값은 600초입니다. |
| `LastData` | `{[string]: Data}` | 키별 로컬 래퍼 캐시입니다. |
| `RemovedKeys` | `{[string]: number}` | 로컬에서 확인한 tombstone 만료 시각입니다. |
| `PendingDataSave` | `{[string]: boolean}` | 백그라운드 DataStore 저장 재시도 상태입니다. |
| `PendingMemoryPublish` | `{[string]: {revision: number}}` | 확정된 영구 버전의 공유 캐시 재게시 상태입니다. |
| `PendingMemoryRemoval` | `{[string]: table}` | 공유 삭제 표식 재게시 상태입니다. |
| `IsGetting` | `{[string]: boolean}` | 키별 읽기 진행 상태입니다. |
| `IsSaving` | `{[string]: boolean}` | 키별 쓰기 진행 상태입니다. |
| `DataTemplate` | `table` | 영구 데이터 기본 템플릿입니다. |
| `MemoryTemplate` | `table` | 임시 상태 기본 템플릿입니다. |

`Store`, `Map`, `MapName`도 노출되지만 KrossSync와 동시에 원시 저장소를 수정하면 캐시와 서버 간 상태가 어긋날 수 있습니다.

## 읽기

### `Get()`

```luau
KrossSync:Get(key: string, force: boolean)
    -> Data | false, { Data: boolean, Memory: boolean }?
```

MemoryStore를 먼저 조회합니다. 값이 없으면 DataStore에서 복구하고 두 저장소에 키가 없으면 템플릿 `data`를 `SaveData`로 영구 저장한 뒤 MemoryStore에 전체 래퍼를 만듭니다. 신규 키 조회도 영구 쓰기 요청을 소비하므로 존재 확인만 하는 순수 조회로 취급하지 마세요.

신규 생성 중 영구 저장만 성공하고 공유 저장이 실패하면 `memory=nil`인 부분 래퍼와 `{Data=true, Memory=false}`를 반환할 수 있습니다. 두 번째 상태 table은 모든 경로에서 반환되는 값이 아닙니다.

`force=true`는 서비스 상태와 Critical 검사를 우회하지만 같은 키의 `IsGetting`·`IsSaving` 잠금은 우회하지 않습니다.

### `GetData()`

```luau
KrossSync:GetData(key: string, force: boolean)
    -> Data | nil | false
```

DataStore의 raw data와 영구 버전을 읽고 삭제 표식을 확인한 뒤 공유 래퍼와 결합합니다. 키가 없으면 `nil`, 삭제 상태나 요청·동기화 실패면 `false`를 반환합니다. 더 최신인 MemoryStore의 미저장 변경을 보존할 수 있으므로 반환된 `data`가 반드시 영구 값과 동일하지는 않습니다. 캐시 갱신과 MemoryStore 복구도 수행할 수 있습니다.

반환값만으로 특정 쓰기 요청의 영구 반영 여부를 확정할 수 없습니다. 실패한 증가·지급의 새 호출 재시도를 결정하는 증거로 사용하지 마세요. 안전한 재시도가 필요하면 호출 코드가 고유 요청 ID와 처리 결과를 영구 `data`에 함께 기록하고 같은 ID의 중복 적용을 막아야 합니다.

### `GetMemory()`

```luau
KrossSync:GetMemory(key: string, force: boolean)
    -> Data | nil | false
```

MemoryStore의 전체 래퍼를 읽습니다. 현재 `game.JobId`가 없거나 서버 목록 정규화가 필요하면 `UpdateAsync`로 최신 값을 다시 읽어 현재 서버를 한 번만 등록합니다. 활성 tombstone을 발견하면 로컬 캐시를 폐기하고 `false`를 반환합니다.

## 저장

### `Set()`

```luau
KrossSync:Set(
    key: string,
    update: Data | ((old: DataTemplate?) -> DataTemplate?),
    expiration: number?,
    force: boolean?
) -> (dataSaved: boolean, memorySaved: boolean)
```

DataStore에 `UpdateAsync`로 먼저 저장한 뒤 확정된 버전을 MemoryStore에 게시합니다. 테이블 입력은 전체 래퍼의 `.data`를 저장하며 함수 입력은 기존 영구 `data`를 받습니다.

`(true, false)`면 영구 저장은 완료됐지만 공유 캐시 게시가 남았습니다. 5초 간격으로 재전달을 시도하며 재시도 기간은 `expiration` 또는 `ExpirationTime`입니다. 서버 종료 시 작업이 중단될 수 있습니다. 더 새 버전은 덮어쓰지 않으며 `UnSync` 이후 재전달은 키를 다시 구독하지 않습니다.

`(false, false)`는 요청 실패, 삭제, 오래된 래퍼, 동시 쓰기 충돌, 로컬 잠금 등을 포함합니다. 실패 응답만으로 미반영을 단정하지 마세요. 비멱등 변경을 새 호출로 즉시 반복하면 중복 적용될 수 있습니다.

### `SetMemory()`

```luau
KrossSync:SetMemory(
    key: string,
    update: Data | ((old: Data?) -> Data?),
    expiration: number?,
    force: boolean?
) -> boolean
```

`SaveMemory`와 같은 전체 래퍼 입력으로 공유 캐시를 갱신합니다. 일반 갱신은 DataStore를 읽지 않지만 공유 항목이 누락되면 영구 상태와 삭제 여부를 확인해 복구합니다. `true`는 MemoryStore 쓰기 성공이며 영구 저장이나 모든 서버의 수신 완료를 뜻하지 않습니다. `false`이면 상태를 확인한 뒤 재시도 여부를 결정하세요.

### `Save()`

```luau
KrossSync:Save(
    key: string,
    data: Data | ((old: Data?) -> Data?),
    expiration: number,
    force: boolean
) -> boolean
```

일반 저장 진입점입니다. `dataCreateTime` 기준 60초 미만이면 MemoryStore만 갱신하고, 60초 이상이면 MemoryStore를 먼저 갱신한 뒤 확정된 `data`를 DataStore에 저장합니다. 이 조건은 `Save()`가 호출될 때만 검사되며 백그라운드 자동 저장 타이머가 아닙니다.

MemoryStore는 저장됐지만 DataStore 저장만 실패하면 `Save`는 함수형 콜백의 중복 실행을 피하기 위해 논리적 성공인 `true`를 반환하고, 최신 로컬 값을 백그라운드에서 다시 저장합니다. 따라서 `true`가 즉시 영구 저장 완료를 항상 의미하지는 않습니다.

함수형 입력은 항상 최신 전체 래퍼를 받습니다. 콜백은 `UpdateAsync` 충돌 처리 중 여러 번 실행될 수 있으므로 외부 상태를 변경하지 않는 순수 함수로 작성하세요.

### `SaveData()`

```luau
KrossSync:SaveData(
    key: string,
    data: Data | ((old: DataTemplate?) -> DataTemplate?),
    force: boolean
) -> boolean, ("stale" | "uncertain")?
```

테이블·함수 입력 모두 `UpdateAsync`를 사용합니다. 테이블 입력은 전체 래퍼의 `.data`와 저장 순서를 확인하며 오래된 스냅샷은 `(false, "stale")`을 반환합니다. 함수 입력은 기존 raw DataStore 값을 받고 `nil`을 반환하면 취소합니다. 함수형 재시도 중 다른 영구 쓰기와 충돌하면 `(false, "uncertain")`을 반환할 수 있습니다. 삭제 표식은 같은 영구 키의 갱신 콜백에서 확인합니다. MemoryStore에는 자동 게시하지 않으므로 영구 저장 후 공유까지 필요하면 `Set`을 사용하세요.

### `SaveMemory()`

```luau
KrossSync:SaveMemory(
    key: string,
    data: Data | ((old: Data?) -> Data?),
    expiration: number,
    force: boolean
) -> boolean
```

MemoryStore에는 전체 래퍼를 저장하며 table·함수 입력 모두 `UpdateAsync`를 사용합니다. table 입력은 깊은 복사 후 최신 `onlineServers` 목록과 병합되고, 함수 입력은 최신 전체 래퍼를 받습니다. 활성 tombstone은 일반 저장으로 덮어쓸 수 없습니다.

공유 `data`가 바뀌면 변경 순서를 증가시키며 오래된 테이블 입력은 거부합니다. 함수형 콜백의 외부 부작용은 피하세요. 요청별 작업 식별자는 한 호출의 내부 재시도를 보호하며 새 호출까지 중복 적용을 막는 것은 아닙니다.

## 삭제

### `Remove()`

```luau
KrossSync:Remove(key: string) -> (dataRemoved: boolean, memoryRemoved: boolean)
```

DataStore에 만료되지 않는 삭제 표식을 먼저 확정한 뒤 MemoryStore에도 표식을 게시합니다. 공유 표식 TTL은 `ExpirationTime`과 60초 중 큰 값입니다. 영구 표식 때문에 일반 `Get`·`Set`으로 삭제된 키를 재생성하지 않습니다. `data.__krossSyncRemoved`는 내부 예약 필드입니다.

첫 반환값은 영구 표식 기록, 두 번째는 공유 표식 기록 성공 여부입니다. `(true, false)`면 5초 간격으로 공유 표식을 재게시하며 재시도 기간은 공유 표식 TTL입니다. 같은 키가 로컬에서 읽기·쓰기 중이거나 영구 표식 기록이 실패하면 `(false, false)`를 반환합니다.

### `RemoveData()`

```luau
KrossSync:RemoveData(key: string) -> boolean
```

DataStore에 영구 삭제 표식을 남기고 로컬 캐시를 정리합니다. MemoryStore에 즉시 게시하지는 않습니다. 일반 영구 삭제에는 `Remove`를 사용하세요.

### `RemoveMemory()`

```luau
KrossSync:RemoveMemory(key: string) -> boolean
```

MemoryStore 항목과 로컬 캐시만 제거하는 저수준 메서드입니다. DataStore 값이 남아 있으면 다음 `Get`이 전체 래퍼를 다시 만들 수 있습니다.

## 해제

### `UnSync()`

```luau
KrossSync:UnSync(key: string) -> boolean
```

MemoryStore `UpdateAsync`로 현재 서버의 JobId를 제거하고, 그 요청이 확정한 최신 래퍼의 `data`를 영구 저장한 뒤 로컬 동기화를 해제합니다. v0.0.3은 다른 서버 ID가 남아 있어도 저장을 시도하며, 오래된 로컬 스냅샷이나 별도 MemoryStore `GetAsync`를 사용하지 않습니다.

`SaveData`가 더 최신인 영구 값 때문에 `stale`을 반환하면 그 값을 덮어쓰지 않고 해제하며 `true`를 반환합니다. 일반 영구 저장 실패는 재시도할 로컬 래퍼를 유지하고 `false`를 반환합니다. 해제 전에 쓰기를 멈추고 실패한 키는 다시 `UnSync`하세요. 로컬 래퍼가 없으면 `false`이며, 해제 도중 삭제 표식이 확인되면 캐시를 정리하고 `true`가 될 수 있습니다.

일반 경로의 `UnSync`마다 DataStore `UpdateAsync` 요청이 발생할 수 있습니다. 동일 스냅샷은 쓰기를 취소할 수 있지만 요청 비용은 고려해야 합니다. `true`는 모든 서버의 사용 종료나 모든 임시 변경의 영구 보존을 뜻하지 않습니다.

## 신호

### 서비스 신호

```luau
KrossSyncService.OnCriticalToggle:Connect(function(totalCritical, detail)
    -- detail.Total, detail.Data, detail.Memory
end)

KrossSyncService.OnError:Connect(function(position, message, storeName, key, input)
    -- position: 1 = DataStore, 2 = MemoryStore
end)
```

`OnError`는 최종 재시도 후 실패한 읽기, 저장, 삭제와 tombstone 확인에서 발생합니다. `position`은 `1`이면 DataStore, `2`이면 MemoryStore입니다. 일부 내부 확인 오류에서는 마지막 `input` 인수가 생략될 수 있습니다.

### 객체별 신호

```luau
KrossSync.OnNewData:Connect(function(latestWrapper)
end)

KrossSync.OnGettingToggle:Connect(function(isGetting)
end)

KrossSync.OnSavingToggle:Connect(function(isSaving)
end)
```

`OnNewData`는 자동 조회에서 `data` 또는 `memory`의 차이를 발견했을 때 발생합니다. 중간 쓰기마다 발생하는 이벤트가 아니며 삭제 전용 신호도 없습니다. 세 신호 모두 변경된 `key`를 전달하지 않습니다.

> [!WARNING]
> `RemoveData`와 `RemoveMemory`는 다른 저장 계층과 동기화하지 않는 저수준 API입니다. 사용자 데이터의 영구 삭제에는 `Remove`를 우선 사용하세요.

다음: [튜토리얼](Tutorial-KO) · [문제 해결](Troubleshooting-KO) · [v0.0.3 변경점](Changes-KO)
