# KrossSync v0.0.3

[한국어](Home-KO) · [English](Home-EN)

**Roblox 서버의 영구 데이터와 공유 상태를 하나의 Luau API로 관리합니다.**

![Luau](https://img.shields.io/badge/language-Luau-00A2FF)
![version](https://img.shields.io/badge/version-v0.0.3-orange)
![license](https://img.shields.io/badge/license-MIT-blue)

[튜토리얼](Tutorial-KO) · [API](API-KO) · [변경점](Changes-KO) · [문제 해결](Troubleshooting-KO)

> v0.0.3용 로컬 준비 문서입니다. 기준 소스는 `source/NEXT VERSION/V0.0.3/KrossSync.luau`이며 알파 작업본입니다.

KrossSync는 DataStore에 영구 `data`를 저장하고 MemoryStore에 임시 `memory`, 서버 목록, 버전을 포함한 전체 래퍼를 공유하는 서버 전용 모듈입니다. `Set`과 `SetMemory`는 최종 최신 상태를 공유하며 중간 변경은 생략될 수 있습니다.

## v0.0.3 주요 변경

- 키별 자동 조회를 독립시켜 느린 키가 다른 키의 다음 조회를 막지 않게 했습니다.
- 자동 조회에서 예외가 발생해도 작업 상태를 정리하고 다음 조회를 시도합니다.
- `UnSync`는 다른 서버 ID가 남아 있어도 최신 공유 `data`의 영구 저장을 시도합니다.
- 영구 저장 실패 시 재시도할 로컬 래퍼를 유지합니다. 이미 더 최신인 영구 값이 있으면 덮어쓰지 않고 해제합니다.
- 자동 조회 15초, 공유 영구 검증 간격 300초, 저장 형식과 기존 API 반환 계약은 유지합니다. MessagingService는 포함하지 않습니다.

## 시작하기

1. [영어 소스](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KrossSync.luau) 또는 [한국어 소스](https://github.com/NoName-wks/KrossSync/blob/bf2cd0afe1e8e0503def646c7a71f8addb45f9d3/source/NEXT%20VERSION/V0.0.3/KR/KrossSync_KR.luau)를 서버 전용 ModuleScript로 설치합니다.
2. [Signal+](https://github.com/AlexanderLindholt/SignalPlus)(v3.x.x)(Made by AlexanderLindholt)를 `signal`변수에 `require()`합니다. 기본 경로는 `ReplicatedStorage.scr.Library.Signal`입니다.
3. [길드 튜토리얼](Tutorial-KO)에서 생성·가입·공지 공유·해제 흐름을 확인합니다.

기존 `source/KrossSync.luau`는 v0.0.2입니다. 운영 배포에서는 회귀·다중 서버 Script와 `Tests` 폴더를 제외하세요.

## 저장 방법 선택

| 목적 | API | 성공의 의미 |
| --- | --- | --- |
| 중요한 길드 데이터 영구 저장과 공유 | `Set` | `(dataSaved, memorySaved)`로 두 저장소의 결과 확인 |
| 임시 공지 등 상태 공유 | `SetMemory` | MemoryStore 쓰기 성공 |
| 공유 상태 갱신과 조건부 영구 저장 | `Save` | 영구 저장 완료를 항상 뜻하지 않음 |
| 키 사용 종료 | `UnSync` | 최신 공유 `data` 저장 또는 더 최신인 영구 값 보존 후 해제 |
| 길드 영구 삭제 | `Remove` | 영구·공유 삭제 표식 기록 성공 |

`UnSync`마다 DataStore 요청이 발생할 수 있습니다. 중요한 값은 해제까지 기다리지 말고 변경 시 `Set`으로 저장하세요. `memory`는 영구 저장되지 않습니다.

## 검증과 제한

기존 로컬 검증 기록에는 모의 검사 70개, 실제 저장소 집중 검사, 2026-10-18 두 라이브 서버의 정상 종료 테스트 `V3N_0925634e499e` 통과가 있습니다. 상세 범위는 [검증 기록](Changes-KO#검증-기록)에 정리했습니다. 이 문서 작성 중 테스트를 재실행한 결과는 아닙니다.

실제 서버 강제 중단, 실제 서비스의 커밋 후 응답 손실, 운영 규모 부하와 장시간 안정성은 아직 미검증입니다. 두 저장소의 갱신은 원자적이지 않으며 모든 서버가 저장 전에 갑자기 종료되면 MemoryStore 전용 변경이 손실될 수 있습니다. `onlineServers`는 배타적 잠금이나 서버 생존 확인 수단이 아닙니다.

[GitHub 저장소](https://github.com/NoName-wks/KrossSync) · [KrossSync MIT License](https://github.com/NoName-wks/KrossSync/blob/448d5dd307a9ccba75899eb5d832506c6d539f60/LICENSE)
