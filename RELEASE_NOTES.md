# KrossSync v0.0.2 Alpha

## English

Date: 2026-10-09

This alpha release improves cross-server data sharing and storage safety. It is intended for testing and feedback, not as a stable release validated against every production failure scenario.

### Highlights

- Added `Set`. It commits `data` to DataStore first, then publishes the committed revision to MemoryStore.
- Added `SetMemory`. It updates the shared MemoryStore wrapper without writing to durable storage.
- Added revision and change-sequence tracking to prevent stale `SaveData` snapshots from overwriting newer durable data.
- Added operation identifiers and conflict checks to internal retries of function-based writes to guard against duplicate application. The calling code must still handle failures with uncertain outcomes.
- Scheduled durable-state validation every 300 seconds per key, even while the shared cache exists. Normally, one server reads the durable value. If the lease holder stops, another server can take over after the 60-second lease expires.
- If durable storage succeeds but cache publication fails, the committed revision is republished while the server remains alive. Republishing after `UnSync` does not reactivate the local cache or register the server again.
- Added durable deletion markers to guard against deleted data being recreated by delayed writes or stale caches.
- Added regression tests and tests covering concurrent writes, normal shutdown, recovery, load, and injected failures across two real servers.

### Storage API Notes

- External code must call `Set` immediately for important changes that need durable storage. The caller is responsible for deciding which changes are important and when to request a save.
- `Set` returns `(dataSaved, memorySaved)`. `(true, false)` means the durable write is complete, but publication to the shared cache is not yet complete.
- A `true` return from `Save` does not guarantee that a durable write has completed. A successful `SetMemory` also does not mean that all receiving servers have applied the change.
- A function passed to `Set` receives the existing durable `data`. A table passed to `Set` must contain the wrapper's `data` field. `SetMemory` takes the full shared wrapper as input.
- `Set` and `SetMemory` share the final latest state. Intermediate changes may be skipped, and `OnNewData` is not an event stream that delivers every individual save request.
- Do not immediately repeat changes such as `+1` or currency grants in a new call after a failure or cache publication failure. The change may already have been saved, creating a risk of duplicate application.
- For ordinary values, DataStore stores only `data`, while MemoryStore stores the full wrapper. Internal revisions and operation identifiers are recorded in storage metadata or the shared wrapper.

### Verified Test Results

On 2026-10-09, the `Live_1005_02` normal-shutdown test passed across two real live servers. The run used two servers and four load keys. The second server's `passed=true` and `complete=true` results were confirmed in DataStore.

- Passed concurrent `Set` increment preservation, concurrent `SetMemory` field merging, and write/delete race checks.
- Passed first-server shutdown cleanup and removal from the server list.
- Passed recovery of durable values behind stale shared caches, propagation of durable deletion markers, and takeover of expired validation leases.
- Completed 206 load writes across both servers, with zero write failures and zero storage request errors counted.
- Injected eight temporary pre-commit write failures in total; internal retries recovered from them.
- Observed exactly one automatic durable read per recovery key on the observing server, across three recovery keys.
- Measured durable-value recovery and deletion propagation at 297 seconds from the ready timestamp, and recovery of the lease-takeover target at 71 seconds. These are measurements from this run, not recovery-time guarantees.

There is also an earlier record of 62 passing Studio regression tests. Those regression tests were not rerun when these release notes were written.

### Known Limitations

- Changes stored only in MemoryStore may be lost if all related servers stop or the entry expires. Use `Set` to durably save important values.
- Durable writes and shared-cache updates are not atomic across the two storage services. If a server stops before publication, other servers may see stale cache data until recovery.
- Automatic validation depends on polling intervals and storage availability, so recovery within exactly 300 seconds is not guaranteed. Do not rely solely on the shared cache for important decisions.
- Real abrupt server termination, post-commit response loss from the actual services, production-scale load, and long-term stability have not yet been validated. Injected-failure tests do not reproduce actual service outages.
- This is an alpha release. APIs and internal behavior may change in later versions.

### Installation and Migration Notes

- Do not run V0.0.1 and V0.0.2 against the same stores and keys. Compatibility with the new write ordering and deletion markers is not guaranteed.
- `Remove` and `RemoveData` leave durable deletion markers. Deleted keys are not recreated by ordinary `Get` or `Set` calls. The top-level `data.__krossSyncRemoved` field is reserved for internal markers.
- The English version is `source/KrossSync.luau`; the Korean version is `source/KR/KrossSync_KR.luau`. Choose one version and name its ModuleScript `KrossSync`. V0.0.1 is archived under `legacy/V0.0.1/`.
- Install the Signal+ dependency used by the module at `ReplicatedStorage.scr.Library.Signal`.
- In normal operation, disable `RunTests` on the regression and multi-server test scripts, or exclude those test scripts from deployment.

---

## 한국어

작성일: 2026-10-09

서버 간 데이터 공유와 저장 안전성을 보강한 알파 버전입니다. 테스트와 피드백을 위한 릴리스이며, 운영 환경의 모든 장애 상황을 검증한 안정판은 아닙니다.

### 주요 변경

- `Set`을 추가했습니다. `data`를 DataStore에 먼저 저장한 뒤 확정된 버전을 MemoryStore에 전달합니다.
- `SetMemory`를 추가했습니다. 영구 저장 없이 MemoryStore의 공유 래퍼를 갱신합니다.
- 저장 버전과 변경 순서를 추적해 오래된 `SaveData` 스냅샷이 최신 영구 값을 덮어쓰지 않도록 보강했습니다.
- 함수형 저장의 내부 재시도에 작업 식별자와 충돌 검사를 적용해 같은 변경의 중복 적용을 방어합니다. 결과가 불확실한 실패는 여전히 호출 코드가 처리해야 합니다.
- 공유 캐시가 남아 있어도 키별 300초 간격의 영구 상태 검증을 예약합니다. 정상 검증에서는 서버 하나가 영구 값을 읽으며, 예약 주체가 중단되면 60초 예약 만료 후 다른 서버가 이어받습니다.
- 영구 저장 후 캐시 반영만 실패한 경우 서버가 살아 있는 동안 확정된 버전을 재전달합니다. `UnSync` 이후의 재전달은 로컬 캐시나 서버 등록을 다시 활성화하지 않습니다.
- 영구 삭제 표식을 사용해 늦은 저장이나 오래된 캐시가 삭제된 데이터를 다시 만들지 않도록 보강했습니다.
- 회귀 테스트와 실제 두 서버의 동시 저장, 정상 종료, 복구, 부하 및 장애 주입 테스트를 추가했습니다.

### 저장 API 사용 시 주의

- 중요한 변경은 외부 코드가 즉시 `Set`을 호출해 영구 저장해야 합니다. 중요도 판단과 저장 요청 시점은 호출 코드의 책임입니다.
- `Set`은 `(dataSaved, memorySaved)`를 반환합니다. `(true, false)`이면 영구 저장은 완료됐지만 공유 캐시 반영은 아직 완료되지 않은 상태입니다.
- `Save`가 `true`를 반환해도 영구 저장 완료를 뜻하지 않습니다. `SetMemory`의 성공도 모든 수신 서버의 적용 완료를 뜻하지 않습니다.
- `Set`의 함수 입력은 기존 영구 `data`를 받습니다. 테이블 입력은 래퍼의 `data` 필드가 필요합니다. `SetMemory`는 전체 공유 래퍼를 입력으로 사용합니다.
- `Set`과 `SetMemory`는 최종 최신 상태를 공유하는 API입니다. 중간 변경이 생략될 수 있으며, `OnNewData`도 모든 개별 저장 요청을 전달하는 이벤트가 아닙니다.
- 실패 또는 캐시 반영 실패를 이유로 `+1`, 재화 지급 같은 변경을 새 호출로 즉시 재실행하지 마세요. 이미 저장됐을 수 있어 중복 적용 위험이 있습니다.
- DataStore에는 일반 값의 `data`만 저장하고 MemoryStore에는 전체 래퍼를 저장합니다. 내부 버전 및 작업 식별자는 저장소 메타데이터나 공유 래퍼에 기록합니다.

### 확인한 테스트 결과

2026-10-09 실제 라이브 서버 두 개에서 `Live_1005_02` 정상 종료 테스트가 통과했습니다. 서버 두 개와 부하 키 4개를 사용한 실행이며, 두 번째 서버의 `passed=true`, `complete=true`를 DataStore에서 확인했습니다.

- 동시 `Set` 증가분 보존, 동시 `SetMemory` 필드 병합, 저장과 삭제의 경쟁 검사 통과.
- 첫 서버 정상 종료 정리와 서버 목록에서의 해제 검사 통과.
- 오래된 공유 캐시의 영구 값 복구, 영구 삭제 전파, 만료된 검증 예약 인계 검사 통과.
- 양쪽 부하 쓰기 총 206회, 쓰기 실패와 저장소 요청 오류 카운터 각각 0회.
- 커밋 전 임시 쓰기 오류를 총 8회 주입했고 내부 재시도를 통해 복구.
- 복구 대상 키 3개에서 관찰 서버의 자동 영구 읽기 각각 1회.
- 준비 시각 기준 영구 값 복구와 삭제 전파는 297초, 예약 인계 대상 복구는 71초. 이번 실행의 측정값이며 복구 시간 보장이 아닙니다.

기존 Studio 회귀 테스트 62개 통과 기록도 있습니다. 이 노트 작성 시 회귀 테스트를 다시 실행한 것은 아닙니다.

### 알려진 한계

- MemoryStore에만 저장한 변경은 관련 서버가 모두 종료되거나 항목이 만료되면 손실될 수 있습니다. 중요한 값은 `Set`으로 영구 저장하세요.
- 영구 저장과 공유 캐시 갱신은 두 저장소 사이의 원자적 작업이 아닙니다. 게시 전 서버가 종료되면 복구까지 다른 서버가 오래된 캐시를 볼 수 있습니다.
- 자동 검증은 조회 주기와 저장소 상태의 영향을 받으므로 정확히 300초 이내 복구를 보장하지 않습니다. 중요한 판단에 공유 캐시만 사용하지 마세요.
- 실제 서버 강제 중단, 실제 서비스의 커밋 후 응답 손실, 운영 규모의 부하 및 장시간 안정성은 아직 검증하지 않았습니다. 장애 주입 테스트는 실제 서비스 장애의 재현을 뜻하지 않습니다.
- 알파 단계이므로 API와 내부 동작이 후속 버전에서 변경될 수 있습니다.

### 적용 시 주의

- V0.0.1과 같은 저장소 및 키를 혼합 운영하지 마세요. 새 저장 순서와 삭제 표식의 호환성을 보장하지 않습니다.
- `Remove`와 `RemoveData`는 영구 삭제 표식을 남깁니다. 삭제된 키는 일반 `Get`이나 `Set`으로 재생성하지 않습니다. 최상위 `data.__krossSyncRemoved`는 내부 표식용 예약 필드입니다.
- 영어 버전은 `source/KrossSync.luau`, 한국어 버전은 `source/KR/KrossSync_KR.luau`입니다. 두 버전 중 하나를 선택하고 ModuleScript 이름을 `KrossSync`로 지정하세요. V0.0.1은 `legacy/V0.0.1/`에 보관합니다.
- 모듈이 사용하는 `ReplicatedStorage.scr.Library.Signal`의 Signal+ 의존성을 설치해야 합니다.
- 일반 운영에서는 회귀 및 다중 서버 테스트의 `RunTests`를 끄거나 테스트 Script를 배포에서 제외하세요.
