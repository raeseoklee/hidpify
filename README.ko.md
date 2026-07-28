[English](./README.md) · **한국어**

<img src="./docs/images/app-icon.png" alt="hidpify 앱 아이콘" width="88" align="right">

# hidpify

[![Release](https://img.shields.io/github/v/release/raeseoklee/hidpify)](https://github.com/raeseoklee/hidpify/releases)
[![License](https://img.shields.io/github/license/raeseoklee/hidpify)](./LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20·%20Apple%20Silicon-black)
[![Homebrew](https://img.shields.io/badge/homebrew-raeseoklee%2Ftap-orange)](https://github.com/raeseoklee/homebrew-tap)

macOS에서 HiDPI 모드를 제공하지 않는 외장 모니터에 HiDPI 렌더링을 강제 적용하는 CLI + 상주 데몬입니다. 가상 디스플레이(`CGVirtualDisplay` private API)를 원하는 해상도·HiDPI로 만들고, 그 내용을 실제 모니터에 하드웨어 미러링해서 Apple Silicon(M4 등)의 DCP 물리 파이프 제약을 우회합니다. 설계 배경과 근거는 [DESIGN.ko.md](./DESIGN.ko.md)를 참고하세요.

## 빌드 · 설치

Swift 툴체인 필요(`xcode-select --install`); 모두 소스에서 빌드됩니다.

**메뉴바 앱 + CLI (권장)** — 한 명령으로 Hidpify 메뉴바 앱과 그 앱이 의존하는 CLI/데몬을 함께 설치합니다:

```sh
brew install --cask raeseoklee/tap/hidpify
```

앱은 private API를 써서 공증(notarize)이 불가하므로, **첫 실행 시 macOS Gatekeeper가 막습니다.** `Hidpify.app`을 **우클릭 → 열기**를 한 번 하거나, 격리를 제거하세요: `xattr -dr com.apple.quarantine /Applications/Hidpify.app`.

**CLI만** — 아래 중 아무거나:

```sh
brew install raeseoklee/tap/hidpify                                                       # Homebrew
curl -fsSL https://raw.githubusercontent.com/raeseoklee/hidpify/main/install.sh | bash    # curl | bash
git clone https://github.com/raeseoklee/hidpify.git && cd hidpify && ./install.sh          # 클론에서
```

`install.sh`는 재서명된 `hidpify` 바이너리를 `~/.local/bin`에 설치합니다(`PREFIX=`로 위치 변경, `WITH_AGENT=1`이면 로그인 LaunchAgent도 설치).

또는 수동 빌드/설치:

```sh
swift build -c release          # 빌드만 (.build/release/hidpify)
Scripts/install-cli.sh          # 빌드 + ~/.local/bin/hidpify 설치
```

CLI/데몬 바이너리를 **맨 `cp`로 설치하지 마세요.** `install.sh`와 `Scripts/install-cli.sh`는 복사 후 `codesign --force -s -`로 재서명합니다 — SPM의 linker 서명은 복사 시 무효화되어(`codesign --verify`는 통과하지만) launchd가 실행 시 "Invalid Signature"로 거부해 데몬이 크래시-재시작 루프에 빠지기 때문입니다.

## 명령어

| 명령 | 설명 | 주요 옵션 |
|---|---|---|
| `hidpify list` | 연결된 디스플레이 목록 표 출력 (id, 이름, 해상도, HiDPI 여부, 회전, 가상/미러 여부) | — |
| `hidpify enable` | 대상 디스플레이에 HiDPI 적용 (가상 디스플레이 생성 → 미러링 → 모드 선택) | `--display <이름부분일치\|id>`, `--looks-like WxH`, `--hz <Double>`, `--foreground` |
| `hidpify disable` | 적용 해제 (설정에서 제거 후 데몬 재시작으로 원복) | `--display <이름부분일치>` |
| `hidpify status` | 설정 파일, LaunchAgent 로드 여부, 디스플레이 표 출력 | — |
| `hidpify install-agent` | LaunchAgent 설치 — 로그인 시 데몬 자동 실행 | — |
| `hidpify uninstall-agent` | LaunchAgent 제거 | — |
| `hidpify daemon` | 상주 데몬 실행 (보통 LaunchAgent가 대신 실행) | — |

## 첫 사용 예시

```sh
# 1. 현재 연결된 디스플레이 확인
.build/release/hidpify list

# 2. "DP"라는 이름이 포함된 디스플레이에 HiDPI 적용
.build/release/hidpify enable --display DP

# 3. 결과 확인 (HiDPI:✓ 로 바뀌었는지)
.build/release/hidpify list

# 4. 문제 없으면 로그인 시 자동 적용되도록 영구 등록
.build/release/hidpify install-agent
```

`--display`를 생략하면 비-HiDPI 상태인 물리 디스플레이를 자동으로 찾아 현재 논리 해상도 그대로 HiDPI화합니다. `--looks-like`를 생략하면 대상의 현재 논리 해상도를 그대로 사용하고, `--hz`를 생략하면 현재 주사율을 사용합니다.

## 주의사항

- **private API 사용**: 가상 디스플레이 생성에 CoreGraphics의 비공개 `CGVirtualDisplay*` 클래스를 사용합니다. macOS 업데이트로 시그니처가 바뀌거나 제거될 수 있습니다(런타임에 클래스 존재를 검사해 우아하게 실패 처리).
- **App Store 배포 불가**: private API를 사용하므로 App Store 심사를 통과할 수 없습니다. 개인용 도구로만 사용하세요.
- **잠자기(sleep) 시 동작**: 잠자기 진입 시 가상 디스플레이를 분리하고, 깨어날 때 동일한 신원(serialNum)으로 재생성하여 미러링·모드를 다시 적용합니다. 이 과정에서 화면이 잠깐 깜빡일 수 있습니다.
- **일회성 CLI 프로세스는 상태를 유지하지 않음**: `CGVirtualDisplay`는 이를 생성한 프로세스가 객체를 들고 있는 동안만 존재합니다. 따라서 `hidpify enable`은 설정을 저장한 뒤, LaunchAgent가 설치되어 있으면 데몬을 재시작해 적용하고, 없으면 현재 프로세스가 포그라운드 데몬으로 전환되어 유지됩니다(Ctrl-C로 종료하면 원복됩니다). 영구 적용을 원하면 `hidpify install-agent`를 실행하세요.

## Menu Bar App (optional)

| 라이트 | 다크 |
|:---:|:---:|
| <img src="./docs/images/popover-light.png" alt="hidpify 메뉴바 팝오버 (라이트)" width="320"> | <img src="./docs/images/popover-dark.png" alt="hidpify 메뉴바 팝오버 (다크)" width="320"> |

`Scripts/make-app.sh`를 실행하면 `swift build -c release` 후 `dist/Hidpify.app`이 만들어집니다(ad-hoc 서명 포함). 이 앱을 `/Applications`로 복사해 실행하면 됩니다. 메뉴바 팝오버에서 연결된 디스플레이별 HiDPI 토글, "looks like" 해상도 선택(밀도 일치 제안 포함), 데몬 상태 확인, Start at Login을 관리할 수 있습니다. 앱은 순수 프론트엔드로, 가상 디스플레이 생성/미러링은 여전히 `hidpify` 데몬이 전담합니다(DESIGN.ko.md §8.1).

앱은 데몬을 직접 제어하는 컨트롤(헤더의 Start/Stop/Restart)과 로그인 시 자동 실행(Start at Login)을 제공합니다. **데몬은 반드시 독립 `hidpify` CLI 바이너리(`~/.local/bin/hidpify` 등)에서 실행**되며, 앱 번들 내부 바이너리로는 실행하지 않습니다 — ad-hoc 서명된 `.app` 내부의 launchd 실행 바이너리는 taskgated가 "Invalid Signature"로 즉시 종료시켜 데몬이 크래시-재시작 루프(미러링이 붙었다 풀렸다 반복)에 빠지기 때문입니다. 따라서 앱을 쓰려면 먼저 `hidpify` CLI를 표준 경로에 설치해야 하며(설치되지 않으면 데몬 컨트롤과 Start at Login이 비활성화됩니다), 그 결과 화면 기록 권한 목록에는 일반 "exec" 아이콘으로 표시됩니다(정식 Developer ID 서명 전까지의 트레이드오프).

## 스케일링 모드: 미러링 (기본, 권장) vs 스트리밍 (실험적)

- **미러링(기본·권장)**: 가상 디스플레이를 물리 디스플레이에 하드웨어 미러링합니다. 권한이 필요 없고 지연이 없으며 안정적입니다. 유일한 단점은 아래 Spaces 전환 버그입니다.
- **스트리밍(experimental)**: 가상 디스플레이를 독립 확장 디스플레이로 두고 그 화면을 물리 디스플레이에 실시간 캡처·표시합니다. 미러 세트가 아니므로 **Spaces 전환 제스처가 정상 동작**하지만, 아래의 실험적 한계가 있어 **Spaces 스와이프가 꼭 필요한 경우에만** 권장합니다.

```sh
hidpify enable --display LG --mode stream    # 스트리밍(실험적)으로 적용
hidpify enable --display LG --mode mirror    # 미러링(기본)으로 되돌리기
```

**스트리밍 모드의 실험적 한계 (알아두세요):**
- **유령 데스크탑**: 물리 디스플레이가 배치에 자기 데스크탑을 그대로 유지합니다(스트림은 그 위에 얹힘). 커서가 못 가게 배치 맨 아래 "고립 섬"으로 밀어두지만, **전체화면 앱(예: 원격 데스크탑)을 그 위에서 쓰면 내용이 남을 수 있고**, 미션 컨트롤/전체 스크린샷에는 이 유령 데스크탑이 보입니다. 완전 제거는 공개 API로 불가능합니다.
- **화면 기록 권한**: `--mode stream` 첫 실행 시 권한 요청 팝업이 뜹니다. **시스템 설정 > 개인정보 보호 및 보안 > 화면 기록**에서 hidpify를 허용한 뒤 다시 실행하세요. 없으면 미러링으로 폴백합니다.
- **재빌드 시 권한 재부여**: ad-hoc 서명이라 바이너리를 재빌드하면 cdhash가 바뀌어 화면 기록 권한이 무효화됩니다. 권한을 다시 허용해야 합니다.
- **전력/GPU**: 고해상도 백킹을 실시간 캡처·합성하므로 미러링보다 무겁습니다(캡처는 60fps로 제한).

- **알려진 macOS 제약 — 미러 세트의 Spaces 전환**: 가상 디스플레이를 미러링하는 화면에서는 트랙패드 스와이프/키보드 단축키로 데스크탑(Spaces)을 전환하지 못합니다. 미러 세트의 Spaces 전환 불가는 Sidecar·DisplayLink·AirPlay 공통의 알려진 macOS 동작입니다. **근본 해결은 위의 스트리밍 모드**이며, 미러링을 유지하려면 Mission Control을 연 뒤 상단 Spaces 바에서 클릭하거나 "디스플레이별 개별 공간"을 끄면 됩니다.

## 라이선스

[Apache License 2.0](./LICENSE) — © 2026 raeseoklee

## 감사의 말 (Acknowledgments)

- [smcleod.net의 M4/M5 HiDPI 제약 분석](https://smcleod.net/2026/03/new-apple-silicon-m4-m5-hidpi-limitation-on-4k-external-displays/) — 가상 디스플레이 방식 채택의 근거
