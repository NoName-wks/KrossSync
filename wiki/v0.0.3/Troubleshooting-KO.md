# 문제 해결 및 알려진 제한

[한국어](Troubleshooting-KO) · [English](Troubleshooting-EN)

v0.0.3 준비 문서입니다. [v0.0.3 작업본](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KrossSync.luau)을 기준으로 합니다.

## 알려진 제한

- DataStore와 MemoryStore의 갱신은 원자적이지 않습니다.
- `onlineServers`는 배타적 세션 락이 아닙니다.
- `SetMemory`와 `OnNewData`는 모든 중간 변경의 전달을 보장하지 않습니다.
- MemoryStore 전용 변경은 만료나 관련 서버 중단으로 손실될 수 있습니다.
- 자동 영구 검증은 키별 300초 간격으로 예약되지만 오류·인계로 늦어질 수 있습니다.
- 함수형 저장 콜백은 여러 번 실행될 수 있습니다. 외부 부작용을 피하세요.
- 오래된 스냅샷은 자동 병합하지 않습니다.
- 서버 종료 정리는 최종 저장을 보장하지 않습니다.
- 실제 두 서버의 정상 종료 검사는 통과했지만 실제 강제 중단·서비스 응답 손실·운영 규모 부하·장시간 안정성은 아직 미검증입니다.

## Signal 모듈을 찾지 못함

[Signal+](https://github.com/AlexanderLindholt/SignalPlus)를 `ReplicatedStorage.scr.Library.Signal`에 배치하거나 소스의 `require` 경로를 맞추세요.

## 저장소 접근 오류 또는 준비 지연

게시된 테스트 Experience인지, Studio의 **Enable Studio Access to API Services**가 켜져 있는지 확인합니다. 서버 Output과 `State`, `IsCritical`, `OnError`를 함께 확인하세요.

## 호출이 끝나지 않음

`MaxRetryTime`은 기본 5회이며 `nil`이면 무한 시도합니다. 숫자는 내림한 뒤 최소 1회로 보정됩니다. 저장소 I/O와 백오프 중 yield할 수 있습니다.

## `get()`이 `false` 반환

동일 StoreName을 다시 열 때 최초 `DataTemplate`과 `MemoryTemplate` 테이블의 참조를 재사용해야 합니다.

## 읽기·쓰기가 `false` 반환

서비스 상태, 치명 상태, 같은 키의 `IsGetting`·`IsSaving`, 삭제 표식, 입력 형태를 확인하세요. `force=true`도 로컬 키 잠금과 삭제 표식을 우회하지 않습니다. 함수 입력은 `Set`·`SaveData`에서 영구 `data`, `Save`·`SetMemory`·`SaveMemory`에서 전체 래퍼를 받습니다.

`Get`이 부분 래퍼를 반환하면 `data`와 `memory`를 모두 확인하고 불완전한 값으로 게임을 진행하지 마세요.

## `Set()`이 `(true, false)` 반환

영구 저장은 성공했고 공유 캐시 게시가 남았습니다. 같은 증가·지급을 새 `Set` 호출로 반복하지 마세요. `PendingMemoryPublish[key]`와 Output을 확인합니다. 재전달은 5초 간격으로 시도하고 요청의 만료 시간까지 진행되며 서버가 종료되면 중단됩니다.

## `Set()` 또는 `SetMemory()` 실패 후 재시도

실패 응답은 미반영을 확정하지 않습니다. 한 호출 내부의 작업 식별자 보호는 새 API 호출까지 중복 적용을 방지하지 않습니다. `GetData`의 반환 `data`에도 MemoryStore의 미저장 변경이 포함될 수 있으므로 그 값만으로 영구 반영 여부를 확정하지 마세요.

길드 멤버 추가처럼 반복해도 결과가 같은 변경으로 설계하세요. 증가·지급처럼 효과가 누적되는 작업의 안전한 재시도가 필요하면 호출 코드가 고유 요청 ID와 처리 결과를 영구 `data`에 함께 기록하고 같은 ID의 중복 적용을 막아야 합니다.

## `SaveData()`가 `stale` 또는 `uncertain` 반환

`(false, "stale")`은 전달한 래퍼가 영구 저장 순서보다 오래된 경우입니다. `(false, "uncertain")`은 함수형 재시도 중 다른 영구 쓰기와 충돌한 경우입니다. 최신 상태를 다시 확인하고 충돌을 처리하세요. 오래된 래퍼를 강제로 덮어쓰거나 비멱등 콜백을 곧바로 반복하지 마세요.

## `Save()`가 성공했는데 영구 값이 바뀌지 않음

60초는 자동 저장 타이머가 아니라 호출 시 조건입니다. MemoryStore 갱신 후 영구 저장이 실패하거나 오래된 스냅샷이 거부돼도 `Save`가 `true`를 반환할 수 있습니다. 중요한 값은 `Set`으로 저장하고 첫 반환값을 확인하세요.

## 다른 서버 변경이 바로 보이지 않음

자동 조회는 기본 15초 간격이며 중간 상태를 생략할 수 있습니다. `OnNewData`는 자동 조회가 `data` 또는 `memory`의 차이를 발견할 때 전체 래퍼를 전달합니다. 삭제 전용 신호는 없습니다. `SaveData`는 공유 캐시에 자동 게시하지 않습니다.

캐시가 남아 있는 영구 값·삭제 표식은 공유 예약 검증으로 복구될 수 있습니다. 정확히 300초 이내 복구는 보장하지 않습니다. `GetData`는 영구 값을 읽지만 최신 공유 미저장 변경을 반환 래퍼에 보존할 수 있으므로 영구 값만 반환하는 API로 취급하지 마세요.

## 한 키가 느리면 다른 키의 조회도 멈춤

v0.0.3은 키별 자동 조회를 독립적으로 예약합니다. `Automatic memory refresh failed` 경고가 발생해도 작업 상태를 정리하고 다음 조회를 시도합니다. 전체 저장소 장애·서비스 상태·Critical의 영향은 별개입니다. 기존 v0.0.2 모듈을 잘못 설치하지 않았는지 확인하세요.

## `UnSync()`가 `false` 반환

로컬 래퍼가 없거나, 같은 키의 작업이 진행 중이거나, 공유 갱신·영구 저장에 실패했을 수 있습니다. 영구 저장 실패 시 재시도할 로컬 값을 유지하므로 새 쓰기를 멈춘 뒤 해제를 재시도하세요. 정상 해제 후 중복 호출하면 로컬 래퍼가 없어 `false`입니다. 더 최신인 영구 값으로 인한 `stale`은 해제 성공으로 처리하며 오래된 값으로 덮어쓰지 않습니다.

## 다른 서버 ID가 남아 있는데 영구 저장됨

v0.0.3의 변경된 동작입니다. `UnSync`는 서버 목록과 관계없이 MemoryStore 갱신이 확정한 최신 `data`를 저장합니다. 정상 해제마다 DataStore 요청이 생길 수 있지만 별도 MemoryStore `GetAsync`는 추가하지 않습니다. `onlineServers`는 서버 생존 여부를 검증하는 목록이나 배타적 잠금이 아닙니다.

## `Remove()`가 `(true, false)` 반환

영구 삭제 표식은 기록됐고 공유 표식 게시가 남았습니다. `PendingMemoryRemoval[key]`와 Output을 확인하세요. 제한된 재시도 기간과 자동 영구 검증을 통해 게시를 시도합니다.

## `Remove()`가 `(false, false)` 반환

로컬 키 잠금 또는 영구 표식 기록 실패일 수 있습니다. 실패 응답만으로 영구 표식이 실제로 기록되지 않았다고 단정하지 마세요. 요청 오류와 두 반환값을 함께 확인하세요.

## 삭제한 키를 다시 열 수 없음

v0.0.3의 `Remove`·`RemoveData`는 만료되지 않는 영구 삭제 표식을 남깁니다. 일반 `Get`·`Set`으로 재생성하지 않습니다. 복원용 공개 API는 없습니다. `data.__krossSyncRemoved`는 예약 필드입니다.

`RemoveMemory`는 캐시만 제거하므로 영구 값이 남아 있으면 다음 조회에서 복구될 수 있습니다. v0.0.1 서버를 같은 키에 혼합 운영하지 마세요.

## 테스트하기

[회귀 테스트](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/Script.legacy.luau)와 [다중 서버 테스트](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/MultiServerTest.server.luau)는 모듈 옆에 배치합니다. 일반 운영에서는 `RunTests=false`로 두거나 테스트 Script를 제외하세요. 별도 Experience와 StoreName을 사용하세요. 기록된 검증 결과와 한계는 [v0.0.3 변경점](Changes-KO#검증-기록)을 확인하세요. 라이브 테스트 결과는 `KrossSync_V003_MULTI_RESULTS`의 RunId 키에 남습니다.

[Issues](https://github.com/NoName-wks/KrossSync/issues)에 보고할 때 버전, 재현 조건, Output, State와 반환값을 포함하세요. 비밀 값이나 실제 플레이어 데이터는 첨부하지 마세요.

[튜토리얼](Tutorial-KO) · [API](API-KO) · [v0.0.3 변경점](Changes-KO)
