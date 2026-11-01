# KrossSync V0.0.3 (Alpha)

V0.0.3 영어 주석 버전은 `source/NEXT VERSION/V0.0.3/KrossSync.luau`, 한국어 주석 버전은 같은 폴더의 `KR/KrossSync_KR.luau`입니다. 폴더 이름은 `NEXT VERSION`이지만 이 README가 안내하는 배포 대상은 그 안의 V0.0.3입니다. 외부 서버 코드가 API를 호출할 때 저장을 요청하며, 어떤 변경이 중요한지는 호출하는 코드가 결정합니다.

**Alpha 릴리스:** 테스트와 피드백을 위한 버전입니다. 기록된 실제 두 라이브 서버의 동시 저장·정상 종료·복구 테스트는 통과했지만, 실제 서버 강제 중단, 서비스 응답 손실, 운영 규모 부하 및 장시간 안정성은 아직 미검증입니다. 변경점과 제한은 아래에 정리했습니다.

## V0.0.3 변경점

- 키별 자동 조회를 독립시켜 한 키의 느린 요청·예외가 다른 키의 조회를 막지 않도록 했습니다.
- `UnSync`는 다른 서버 ID가 남아 있어도 MemoryStore의 최신 확정 `data`를 영구 저장합니다. 별도 MemoryStore 읽기 요청은 추가하지 않습니다.
- `UnSync`의 영구 저장이 실패하면 재시도할 로컬 래퍼를 유지하며, 이미 더 최신인 영구 값은 덮어쓰지 않습니다.
- MemoryStore 자동 조회 15초, 공유 영구 검증 간격 300초와 기존 저장 형식·반환 계약을 유지합니다. MessagingService는 포함하지 않습니다.

## 파일 구성

- [V0.0.3 영어 버전](source/NEXT%20VERSION/V0.0.3/KrossSync.luau)
- [V0.0.3 한국어 버전](source/NEXT%20VERSION/V0.0.3/KR/KrossSync_KR.luau)
- [V0.0.3 Studio 회귀 테스트](source/NEXT%20VERSION/V0.0.3/Script.legacy.luau)
- [V0.0.3 라이브 다중 서버 테스트](source/NEXT%20VERSION/V0.0.3/MultiServerTest.server.luau)
- [V0.0.3 모의 테스트 실행기](source/NEXT%20VERSION/V0.0.3/Tests/RunTests.luau)
- [기존 V0.0.2 영어 버전](source/KrossSync.luau)
- [기존 V0.0.2 한국어 버전](source/KR/KrossSync_KR.luau)
- [V0.0.1 레거시](legacy/V0.0.1/KrossSync.lua)
- [V0.0.1 한국어 레거시](legacy/V0.0.1/Korean/KrossSync_KR.lua)
- [V0.0.0 레거시](legacy/V0.0.0/KrossSync.lua)

## 설치와 배포

1. 위 V0.0.3 영어 또는 한국어 버전 중 하나만 서버의 ModuleScript로 설치하고 이름을 `KrossSync`로 지정합니다. 기존 `source/KrossSync.luau`는 V0.0.2이므로 혼동하지 마세요.
2. `ReplicatedStorage.scr.Library.Signal`에 Signal+ 의존성을 설치합니다. Studio의 실제 저장소 검사는 게시된 테스트 플레이스에서 API Services 접근을 허용해야 합니다.
3. 운영 배포에서는 회귀·다중 서버 Script와 `Tests` 폴더를 제외합니다. 테스트용으로 유지한다면 Script를 비활성화하고 `RUN_TESTS=false`, `RunTests=false`를 확인한 뒤 게시합니다. Studio에서만 바꾸고 게시하지 않으면 기존 서버에는 반영되지 않습니다.
4. 중요한 변경은 외부 코드가 즉시 `Set`을 호출하고 첫 번째 반환값을 확인합니다. `Save`나 `SetMemory`의 성공을 영구 저장 완료로 취급하지 않습니다.
5. 기존 운영 데이터는 백업하고 테스트 키로 먼저 확인하세요. 서로 다른 버전의 서버를 혼합 운영하는 호환성은 별도 검증이 필요합니다.

저장소에는 코드와 README·WIKI만 게시합니다. 상세 HTML 문서·개별 결과 파일은 로컬 참고용이며 설치에 필요하지 않습니다.

## 저장 API

`Set`과 `SetMemory`는 각 변경을 개별 전달하는 이벤트 API가 아니라 최종 최신 상태를 공유하는 API입니다. 수신 서버가 늦게 조회하면 중간 값은 생략될 수 있습니다. `OnNewData`도 개별 저장 요청이 아니라 조회에서 발견한 상태 변경을 알립니다. 서버 종료 뒤 최신 상태 복구와 삭제 안전성은 별도로 충족해야 하는 요구사항입니다.

- `Save(key, update)`는 MemoryStore에 변경을 반영합니다. 마지막 DataStore 저장 후 60초가 지났다면 `data`도 영구 저장합니다. `true`가 항상 DataStore 저장 완료를 뜻하지는 않습니다.
- 영구 저장할 필요 없이 서버 간에 전달할 변경은 `SetMemory(key, update)`를 사용합니다. `SaveMemory`와 같은 래퍼 입력을 받으며, MemoryStore 항목이 누락된 경우에만 DataStore의 삭제 여부를 확인합니다.
- 중요한 `data` 변경은 `Set(key, update)`를 사용합니다. DataStore에 먼저 확정한 다음 MemoryStore에 반영하며 `(dataSaved, memorySaved)`를 반환합니다. 둘 다 `true`이면 두 저장소에 반영된 것입니다. 각 서버의 처리 완료를 확인하는 반환값은 아닙니다.

```luau
local dataSaved, memorySaved = sync:Set(key, function(current)
	current.coins += amount
	return current
end)

if not dataSaved then
	-- 결과가 불확실할 수 있으므로 같은 변경을 바로 재호출하지 마세요.
	return false
end

if not memorySaved then
	-- 영구 저장은 완료됐습니다. Set을 다시 호출하면 중복 지급될 수 있습니다.
	-- 서버가 살아 있는 동안 MemoryStore 반영을 자동 재시도합니다.
	return false
end

return true
```

`Set`에 테이블을 넘기면 래퍼의 `data` 필드만 영구 저장합니다. 함수 입력에는 DataStore의 기존 `data` 값이 전달됩니다. 오류 재시도로 한 번의 `Set` 호출에서 DataStore `UpdateAsync`가 여러 번 요청될 수 있습니다. 각 요청은 읽기·쓰기 예산을 모두 소비합니다.

함수형 `Set`/`SaveData`/`SetMemory`는 요청별 작업 식별자를 기록해 응답 손실 후 같은 작업을 다시 적용하지 않습니다. 다른 서버의 쓰기가 그사이에 기록을 바꾸면 재적용하지 않고 실패를 반환합니다. 이미 반영됐는지 판정할 수 없는 실패도 있으므로, 비멱등 변경은 최신 값을 확인하지 않고 새 호출로 재시도하면 안 됩니다. 함수형 `SaveData`가 재시도 중 다른 영구 쓰기와 충돌하면 `(false, "uncertain")`을 반환할 수 있습니다.

`SaveData`에 MemoryStore에서 받은 래퍼를 넘기면 DataStore 메타데이터의 저장 순서와 비교합니다. 오래된 래퍼는 `(false, "stale")`을 반환하고 영구 데이터를 덮어쓰지 않습니다. `SaveMemory`로 data를 바꾸면 공유 래퍼의 변경 순서가 증가합니다. `SaveData(function)`은 DataStore의 현재 값만 변환하며 MemoryStore에는 자동 전달하지 않습니다. `Save`가 `true`를 반환해도 DataStore 저장이나 충돌 해결까지 완료됐다는 뜻은 아닙니다.

자동 조회에서 다른 인스턴스의 `data` 또는 `memory` 변경을 발견하면 `OnNewData`가 전체 래퍼를 전달합니다.
일반 자동 조회와 MemoryStore 갱신은 DataStore를 읽지 않습니다. 캐시가 남아 있어도 키별로 5분마다 공유 검증 예약을 확보한 서버 하나가 영구 값과 삭제 표식을 확인합니다. 정상 검증은 DataStore 읽기 1회와 MemoryStore 예약·완료 쓰기 각 1회를 추가하며, 값 복구나 삭제 표식 게시가 필요하면 추가 MemoryStore 쓰기가 발생합니다. 동시 예약 경쟁과 오류 재시도는 요청을 더 사용할 수 있습니다. 검증 서버가 종료되면 60초 예약 만료 뒤 다른 서버가 이어받으며, 너무 오래 걸린 요청은 예약 만료와 겹칠 수 있습니다. 검증 실패 시 다음 자동 조회부터 재시도합니다. MemoryStore 항목이 누락된 경우에도 영구 값과 삭제 표식을 확인한 뒤 복구하며, DataStore 조회 실패 시 이전 로컬 값으로 복구하지 않습니다.

`Set`에서 DataStore만 성공하면 동일한 저장 버전의 MemoryStore 반영을 서버가 살아 있는 동안 재시도합니다. 공유 캐시가 남아 있으면 DataStore를 다시 호출하지 않으며, 캐시가 사라지면 영구 값과 삭제 표식을 확인한 뒤 복구합니다. 더 새 버전은 덮어쓰지 않습니다. `UnSync` 성공 후에도 확정된 값의 재전달은 계속하지만 로컬 캐시를 새로 만들거나 현재 서버를 다시 등록하지 않습니다. 명시적으로 다시 조회해 동기화를 재개한 키의 캐시는 계속 갱신합니다.

`UnSync(key)`는 최신 공유 래퍼에서 현재 JobId를 제거한 뒤 그 확정 결과의 `data`를 영구 저장합니다. 다른 서버 ID의 존재 여부와 무관하게 영구 저장 요청이 발생할 수 있습니다. 성공 또는 더 최신 영구 값 확인 시 로컬 캐시를 해제하고, 실패 시 재시도할 값을 유지합니다. 모든 서버가 저장 전에 갑자기 종료되는 상황까지 보장하지는 않습니다.

중요한 판단 직전에는 `LastData`나 `Get`의 공유 캐시만 믿지 말고 `GetData(key)`로 DataStore를 확인하세요. `false`이면 조회·동기화 실패 또는 삭제 상태이고, `nil`이면 영구 키가 없습니다. 두 경우 모두 기존 캐시로 그 판단을 진행하지 마세요. 반환된 래퍼는 더 최신인 MemoryStore의 미저장 변경을 보존할 수 있으므로, `data`가 반드시 영구 저장된 값과 같다는 뜻은 아닙니다.

영구 값이 그대로여도 최신 공유 임시 필드와 서버 목록을 반영합니다. 삭제 확인에서 이미 읽은 래퍼를 재사용하며, 영구 데이터 병합이나 서버 등록이 필요하지 않으면 추가 쓰기를 하지 않습니다.

```luau
local latest = sync:GetData(key)
if not latest then
	return false
end

-- 이후 판단에는 기존 캐시 대신 latest.data를 사용합니다.
```

임시 상태 변경은 `SetMemory`의 반환값을 확인하세요. `false`이면 반영 성공으로 취급하지 않습니다. 응답 손실로 이미 적용됐을 수도 있으므로, `+1` 같은 변경을 새 호출로 바로 재시도하지 말고 현재 상태를 확인하세요. `true`는 MemoryStore 반영 성공이며, 모든 수신 서버의 최신 상태 적용 완료를 확인한 것은 아닙니다.

```luau
local delivered = sync:SetMemory(key, function(current)
	current.memory.remoteMarker = marker
	return current
end)
if not delivered then
	return false
end
```

`Remove(key)`는 DataStore에 만료되지 않는 삭제 표식을 먼저 기록하고 MemoryStore에도 삭제 표식을 기록합니다. 두 반환값이 모두 `true`일 때 삭제 완료로 처리하세요. MemoryStore 표식만 실패하면 서버가 살아 있는 동안 재시도합니다. `RemoveData(key)`도 DataStore 값을 물리적으로 없애는 대신 영구 삭제 표식을 남깁니다. 일반 데이터 값은 기존처럼 `data`만 저장하고, 삭제된 키에만 작은 표식이 남습니다. `data`의 최상위 필드 이름 `__krossSyncRemoved`는 내부 표식용으로 예약합니다.

## 현재 한계

MemoryStore에만 반영된 변경은 모든 관련 서버가 갑자기 종료되거나 항목이 만료되면 손실될 수 있습니다. `Set`에서 DataStore만 성공한 뒤 서버가 종료되면 다음 공유 검증 전까지 MemoryStore에 이전 값이 남을 수 있습니다. DataStore 삭제 표식만 기록된 경우에도 다음 공유 검증이 MemoryStore에 표식을 게시합니다. 검증은 일반 자동 조회에서 실행되므로 정확히 5분 이내 복구를 보장하지 않으며, 저장소 장애나 예약 만료·재시도로 더 늦어질 수 있습니다. 중요한 판단은 계속 `GetData`로 확인해야 합니다. `SaveData`가 오래된 래퍼를 거부한 경우 자동 병합은 하지 않으므로 호출 코드가 충돌을 처리해야 합니다. 삭제 확인과 MemoryStore 재게시 사이의 경쟁은 두 저장소 사이의 원자적 작업으로 막을 수 없습니다. V0.0.1 서버는 새 저장 순서와 삭제 표식을 해석하지 못하므로 혼합 운영도 안전하지 않습니다. 모의 장애 테스트와 실제 두 서버의 정상 종료 테스트는 통과했지만, 실제 서비스 응답 손실·서버 강제 중단·운영 규모 부하는 아직 미검증입니다. 알파 단계이므로 운영 환경 전체의 안정성을 보장하지 않습니다.

## 기록된 검증

아래는 기존 V0.0.3 실행 기록의 요약입니다. README 정리 과정에서 테스트를 새로 실행한 결과는 아닙니다.

| 구분 | 확인한 범위 | 결과 |
| --- | --- | --- |
| 모의 저장소 | 기존 회귀 62개, 조회 격리·예외 복구 2개, UnSync 5개, 별도 충돌 모형 1개 | 총 70개 통과 기록 |
| 실제 저장소 · Studio Edit | 독립 모듈 인스턴스의 조회 격리·예외 복구, 최신 공유 값 UnSync 저장, 더 최신 영구 값 보호 | 통과 기록 · 실제 두 라이브 서버 검증과 구분 |
| 실제 라이브 서버 2개 | 동시 Set·SetMemory, 최신 공유 값 UnSync, 삭제 경쟁, 정상 종료, 복구, 부하, 주입 실패 재시도 | 2026-10-18 통과 기록 |
| 실제 강제 종료·응답 손실·운영 규모·장시간 안정성 | 실제 장애 상황 | 미검증 |

라이브 정상 종료 실행은 `V3N_0925634e499e`, PlaceVersion `1039`입니다. 서로 다른 JobId의 두 서버를 사용했고, 첫 서버의 `close.ready=true`·`close.completed=true`와 두 번째 서버의 `passed=true`·`complete=true`를 확인한 기록입니다. 부하 시작부터 완료까지 373초였으며 요청 오류와 쓰기 실패는 양쪽 모두 0회였습니다. 커밋 전 MemoryStore 오류는 서버별 4회씩 의도적으로 주입했습니다.

이 실행의 복구 시간은 예약 인계 71초, 영구 값 294초, 삭제 표식 296초였습니다. 측정값이며 복구 시간 보장은 아닙니다. 종료한 첫 역할의 `complete=false`만으로 전체 실패로 판정하지 않고 두 번째 역할과 정상 종료 기록을 함께 확인합니다. 주입 오류·모의 작업 중단은 실제 서비스 장애나 서버 강제 종료를 검증한 것이 아닙니다.

## 테스트 실행

테스트는 운영 데이터와 분리된 플레이스·저장소에서만 실행하세요. 모듈의 서비스 준비 검사와 실제 저장소 테스트는 API 요청 예산을 소비합니다.

### 모의 저장소 검사

V0.0.3의 `KrossSync` ModuleScript, `Script` 서버 Script, `Tests` 폴더를 같은 테스트 폴더에 구성합니다. Studio Edit 모드의 Command Bar 또는 MCP에서 그 폴더를 `root`로 지정한 뒤 실행합니다.

```luau
local handle = require(root.Tests.RunTests)(root)
print(handle:GetFullName())
```

생성된 폴더의 `Status`가 `Passed`인지, `Result.Value`에 실패가 없는지 확인합니다. `Tests.RunCrashTests`와 `Tests.RunMultiServerTests`는 별도 모형 검사이며 실제 서버 충돌을 의미하지 않습니다.

실제 DataStore/MemoryStore 집중 검사는 `require(root.Tests.RunNativeTests)(root)`, UnSync 집중 검사는 `require(root.Tests.RunNativeTests)(root, "NativeUnSyncTest")`로 실행합니다. 실제 요청을 보내므로 API 접근 설정·예산을 먼저 확인하세요.

### 라이브 다중 서버 검사

V0.0.3 `MultiServerTest.server.luau`를 선택한 모듈 옆의 서버 Script로 설치합니다. Studio 단일 서버에서는 실행되지 않으며 게시된 테스트 플레이스에서 서로 다른 JobId의 두 서버가 필요합니다.

| Script 속성 | 설정 |
| --- | --- |
| `RunTests` | 테스트할 때만 `true`; 종료 후 `false`로 바꾸고 다시 게시 |
| `RunId` | 두 서버에서 동일한 새 ID, 영숫자·`_`·`-`, 최대 24자 |
| `CombinedTests` | 기능·종료 복구·부하를 함께 검사하려면 `true` |
| `LoadKeys` | 기본 4, 허용 1~32 |
| `LoadInterval` | 기본 2초, 허용 1~30초 |
| `InjectFailures` | 기본 `true`; 실제 서비스 장애가 아닌 커밋 전 오류 주입 |
| `ExitMode` | `Normal` 또는 `Abrupt`; 실행마다 새 RunId 사용 |

먼저 참가한 `first` 서버가 `READY_CLOSE_FIRST`를 출력하면 해당 테스트 서버만 종료하고 `second` 서버의 최종 결과를 기다립니다. 스크립트가 서버를 직접 종료하지는 않습니다. 정상 종료는 첫 서버의 종료 정리와 두 번째 서버의 `passed=true`, `complete=true`, 각 검사 결과를 함께 확인합니다.

결과는 DataStore `KrossSync_V003_MULTI_RESULTS`의 RunId 키에 `first`·`second`별로 기록됩니다. 일반 300초 검증을 앞당기지 않아 복구 확인은 준비 후 최대 420초 대기할 수 있습니다. 저장소 지연·장애에 대한 처리 시간 보장은 아닙니다.

`Abrupt`는 종료 콜백이 실행되지 않은 실제 중단을 별도로 확인해야 합니다. heartbeat 중단이나 일반 접속 종료만으로 통과로 판정하지 않습니다. 자동 검사만 끝난 경우 `complete=false`, `requiresExitConfirmation=true`일 수 있으며, 강제 종료 실행의 테스트 키는 자동 정리되지 않습니다. 실제 강제 종료 검증은 아직 남아 있습니다.
