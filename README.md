# 🫑 Paprika

맥북(Apple Silicon 전용) 배터리 **충전 상한 지킴이**. 메뉴바에 파프리카가 하나 뜨고,
충전량만큼 색이 차오른다. 80% 에서 충전을 멈춰 두면 배터리가 훨씬 천천히 늙는다.

배포하지 않는 개인용 앱이다. 서명은 ad-hoc, 공증(notarization)도 없다.

```
┌─────────────────────────────┐
│  🫑 78%                     │  ← 메뉴바
└─────────────────────────────┘
        ↓ 클릭
   충전 상한  ──────●────  80%
   [60] [70] [80] [90] [100]
   ✔ 충전 관리 사용
   ⚡ 이번 한 번만 100% 까지 충전
   ⏸ 잠시 관리 멈추기
   사이클 142 · 건강도 94.1% · 30.2°C
```

---

## 왜 이런 게 필요한가

리튬이온 셀은 **높은 충전 상태로 오래 머무를 때** 가장 빨리 늙는다. 책상에 꽂아두고
쓰는 시간이 길다면 상한을 80% 근처로 잡는 것이 수명에 가장 효과적이다.

macOS 에도 "배터리 충전 최적화"와 (최신 버전의) 80% 제한이 있지만, 값을 직접 고를
수 없고 언제 걸리는지도 예측하기 어렵다. Paprika 는 **20~100% 사이에서 원하는 값**을
직접 정하고, 지금 왜 그렇게 동작하는지를 그대로 보여준다.

---

## 하는 일

| 기능 | 설명 |
|---|---|
| 충전 상한 | 20~100%. 도달하면 충전을 멈추고 벽 전기로만 구동 |
| 히스테리시스 | 상한에 닿은 뒤 `상한 − 여유` 아래로 떨어질 때까지 재충전 안 함 → 충전 사이클 절약 |
| 100% 한 번만 | 외출 전에 눌러두면 100% 채운 뒤 **자동으로** 원래 상한으로 복귀 |
| 강제 방전 | 상한보다 높으면 어댑터를 끊어 상한까지 내림 (지원 기기만) |
| 온도 보호 | 배터리가 설정 온도를 넘으면 충전을 잠시 멈춤 (히스테리시스 포함) |
| 캘리브레이션 | 하한까지 방전 → 100% 충전 → 일정 시간 유지 → 원래 상한 복귀 |
| 일시 중지 | 30분~8시간 동안 관리를 쉬게 함 |
| 기록 | 충전량·온도 그래프 (Swift Charts), JSONL 로 보관 |
| 진단 | SMC 키 덤프, 이벤트 로그, 제어 방식 표시 |
| MagSafe LED | 상태에 따라 색 바꾸기 (실험적, 기본 꺼짐) |

---

## 구조

```
Paprika.app  (메뉴바, 일반 사용자 권한)
     │
     │  XPC  mach service: com.paprika.helperd
     ▼
paprikad     (LaunchDaemon, root)  ──SMC 쓰기──▶  AppleSMC
```

- **왜 두 개로 나누는가**: SMC 쓰기는 root 권한이 필요하다. GUI 앱 전체를 root 로
  돌리는 건 위험하니, 필요한 일만 하는 작은 데몬을 따로 둔다.
- **정책 판단은 데몬 쪽에 있다**: 메뉴바 앱을 종료하거나 로그아웃해도 충전 상한은
  계속 유지된다. 앱은 "보여주고 설정을 바꾸는" 역할만 한다.
- 데몬은 5초(조절 가능)마다 판단하고, **절전에서 깨어날 때**와 **어댑터 연결/분리
  시점**에도 즉시 다시 판단한다. (잠들었다 깨면 SMC 값이 되돌아가는 기기가 있다)

### 소스 지도

파일 배치에는 규칙이 하나 있다: **플랫폼(IOKit/AppKit)에 의존하는 코드와 그렇지 않은
코드를 같은 파일에 섞지 않는다.** 아래 표의 ◆ 표시가 플랫폼 독립 파일이고, 그것들만
모아서 맥 없이도 실제로 실행·검증한다(`make verify`).

```
Sources/
  PaprikaKit/                        앱·데몬·CLI 공용
  ◆ SMC/SMCParamStruct.swift           커널 ABI 80바이트 구조체
  ◆ SMC/SMCValue.swift                 값·오류 타입, 엔디언 디코딩
  ◆ SMC/SMCAccess.swift                SMC 접근 프로토콜 ← 검증용 이음새
    SMC/SMCConnection.swift            실제 IOKit 연결 (SMCAccess 구현)
  ◆ SMC/SMCKeys.swift                  충전 제어 키 정의 + 기대 폭
  ◆ Hardware/ChargeHardware.swift      "충전 허용/차단" 계층 + 기능 탐지
  ◆ Hardware/ChargeApplier.swift       ★ 판단 → SMC 상태 매핑 (가장 위험한 코드)
  ◆ Battery/BatteryPropertyParser.swift 배터리 속성 해석 (순수 함수)
    Battery/BatteryReader.swift        IORegistry 에서 속성 꺼내오기
  ◆ Policy/ChargePolicy.swift          ★ 순수 함수 정책 엔진 (IO 없음)
  ◆ Policy/PaprikaConfig.swift         설정 / 세션 / 캘리브레이션 상태
    IPC/                               XPC 프로토콜 · 스냅샷 · 클라이언트
  paprikad/                          데몬 (제어 루프, XPC 서버, 피어 검증, 절전 감시)
  Paprika/                           메뉴바 앱 (SwiftUI)
    Views/PepperGeometry.swift         파프리카 실루엣 CGPath (아이콘/게이지 공용)
  paprikactl/                        진단용 CLI

Verification/                        검증 하니스 (Scripts/verify.sh 로 실행)
  FakeSMC.swift                        메모리상의 가짜 SMC + 기기 프로파일 6종
  Simulation.swift                     폐루프 시뮬레이션 (정책+적용을 이어서 돌림)
  Shims.swift                          os.Logger / sysctl 대체 (이 둘만)
```

핵심 로직을 읽고 싶다면 두 파일만 보면 된다:

- **`Policy/ChargePolicy.swift`** — "지금 충전할까?"를 결정한다. IO 를 전혀 하지 않는
  순수 함수이고, 판단 순서가 주석에 적혀 있다.
- **`Hardware/ChargeApplier.swift`** — 그 결정을 실제 SMC 값으로 옮긴다. 백엔드별로
  무엇이 다른지가 여기 다 있다.

---

## 설치

Apple Silicon 맥 + macOS 13 이상 + Xcode(또는 Command Line Tools) 가 필요하다.

```bash
git clone <이 저장소>
cd techno

make app          # 빌드 + Paprika.app 번들 + ad-hoc 서명
make deploy       # /Applications 로 복사 (선택)
make install      # 권한 도우미 설치 (sudo 물어봄)
make run          # 앱 실행
```

설치가 끝나면 확인:

```bash
paprikactl status
```

### 로그인 시 자동 실행

앱의 **설정 → 일반 → "로그인할 때 Paprika 실행"**. `SMAppService` 로 먼저 시도하고,
실패하면 `~/Library/LaunchAgents` 에 LaunchAgent 를 직접 넣는 방식으로 넘어간다.
(직접 빌드한 앱에서 `SMAppService` 가 거절되는 경우가 있어서 폴백을 두었다)

---

## 제거

```bash
make uninstall        # 도우미 + 시스템 파일
make uninstall-all    # 사용자 설정·기록까지
```

그 다음 `Paprika.app` 을 휴지통에 버리면 끝이다.

데몬을 멈추면 **SMC 는 자동으로 기본 상태(충전 허용)로 돌아간다.** 언인스톨 스크립트는
그 위에 `paprikad --restore` 를 한 번 더 호출해서, 데몬이 이미 죽어 있었더라도 확실히
되돌린다. 그래도 이상하면 맥을 완전히 껐다 켜면 SMC 값이 초기화된다.

수동으로 되돌리고 싶다면:

```bash
sudo /Library/PrivilegedHelperTools/com.paprika.helperd --restore
```

---

## 충전 제어는 어떻게 동작하나

Apple Silicon 맥은 펌웨어 세대에 따라 충전 제어 방식이 다르다. Paprika 는 macOS
버전으로 추측하지 않고 **SMC 키가 실제로 쓸 수 있는 상태인지** 확인해서 고른다.
(펌웨어만 업데이트된 기기에서 버전 추측은 틀린다)

| 방식 | 키 | 동작 |
|---|---|---|
| `classicLegacy` | `CH0B`, `CH0C` | 1바이트. `0x00` 허용 / `0x02` 차단 |
| `tahoeLegacy` | `CHTE` | 4바이트. `00 00 00 00` 허용 / `01 00 00 00` 차단 |
| `firmware` | `bfF0`, `bfD0`, `bfE0` | 상·하한(%)을 펌웨어에 알려주면 펌웨어가 히스테리시스까지 관리 |

어댑터 차단(꽂은 채로 방전)은 `CH0I` / `CH0J` / `CHIE` 중 있는 것을 쓴다.
**`CHIE` 는 차단 값이 `0x08`** 로 다른 키들(`0x01`)과 다르다.

중요한 세부사항 둘:

1. 최신 펌웨어는 `CH0B` 같은 키를 **`dataSize == 0` 인 껍데기**로만 남겨 두는 경우가
   있다. 존재 여부만 확인하면 "지원됨"으로 오판하므로 크기까지 확인한다
   (`SMCKeyInfo.isUsable`).
2. 크기가 **기대와 다른** 경우도 걸러낸다. 예를 들어 `CHTE` 를 1바이트로 보고하는
   펌웨어에서 4바이트를 쓰려 하면 매번 실패하는데, 그러면 사용자는 원인을 알 수 없다.
   그래서 `SMCKeys.expectedWidths` 와 비교해 다르면 그 이유를 진단 화면에 남긴다.

- 직접 제어(`classicLegacy`/`tahoeLegacy`)가 가능하면 그걸 쓴다 — 온도 보호,
  100% 한 번만 충전, 캘리브레이션처럼 초 단위 개입이 필요한 기능이 다 동작한다.
- 직접 제어 키가 없고 펌웨어 키만 있으면 펌웨어에 위임한다. 이 경우 온도 보호는
  동작하지 않으며, 앱이 그렇다고 알려준다.
- 두 방식이 동시에 걸리면 서로 싸우므로, 직접 제어를 쓸 때는 펌웨어 제한을 먼저 끈다.

---

## 안전에 대해

충전을 막아 둔 상태로 남는 것이 이 앱의 가장 나쁜 실패 모드다. 그래서:

- 데몬이 `SIGTERM`/`SIGINT`/`SIGHUP` 을 받으면 **하드웨어를 먼저 되돌리고** 종료한다.
  이건 설정으로 끌 수 없다. 끌 수 있게 만들면 사용자가 스스로 최악의 상태를 만들 수 있다.
- **배터리를 읽지 못하면 제한을 해제한다.** `AppleSmartBattery` 를 못 읽는 상황에서
  그냥 리턴하면 직전에 걸어둔 충전 억제가 하드웨어에 그대로 남는다. 그래서 읽기 실패를
  "배터리 없음"으로 정책 엔진에 흘려보내 `unmanaged`(= 충전 허용)로 떨어지게 한다.
- `paprikad --restore` 는 데몬도 CLI 도 없어도 SMC 를 되돌린다. 언인스톨 스크립트가
  바이너리를 지우기 **전에** 이걸 호출한다 — 마지막 안전망.
- launchd 설정이 `KeepAlive = { SuccessfulExit = false }` 라서, 정상 종료는 되살리지
  않고 크래시만 되살린다. 언인스톨이 launchd 와 싸우지 않는다.
- 판단이 불가능하거나 오류가 나면 **충전 허용** 쪽으로 기운다. 배터리가 텅 빈 채로
  방치되는 게 100% 로 방치되는 것보다 나쁘다.
- 설정 → 고급 → 복구에서 언제든 수동으로 SMC 를 되돌릴 수 있다 (`paprikactl reset`).
- SMC 쓰기는 값이 실제로 다를 때만 한다.
- 커널에 넘기는 구조체가 80바이트인지 런타임에 검증한다. 어긋나면 SMC 를 아예 건드리지
  않는다 (`SMCParamStruct.byteLayoutIsValid`).

### 권한 경계

데몬 바이너리는 `/Library/PrivilegedHelperTools/com.paprika.helperd` 에 설치된다.
`/usr/local` 을 쓰지 않는 이유: Homebrew 가 설치된 맥에서 `/usr/local` 은 `root:admin`
775 라서 **관리자 계정(= 보통의 사용자 계정)이 root 로 실행될 바이너리를 갈아치울 수
있다.** 그러면 아래의 피어 검증이 아무 의미가 없어진다.

데몬은 XPC 연결을 요청한 프로세스의 **코드서명 identifier** 를 확인한다
(`com.paprika.Paprika`, `Paprika`, `paprikactl`). 정직하게 적어두자면 한계가 둘 있다:

1. PID 기반 확인은 원리상 PID 재사용 경합에 취약하다. 정식 배포 앱이라면 audit token 을
   봐야 하지만 그 API 는 공개돼 있지 않다.
2. ad-hoc 서명에서는 팀 ID 로 묶을 수 없다. identifier 는 비밀이 아니고 ad-hoc 서명은
   인증서가 필요 없으니, 이 검증이 증명하는 것은 "호출자가 스스로 서명했다"는 것뿐이다.
   실질적인 방어선은 위의 설치 경로다.

검증 때문에 막혔을 때의 탈출구:

```bash
sudo ./Scripts/install-helper.sh --allow-unsigned
# 해결한 뒤 이 파일을 지우면 검증이 다시 켜진다:
#   /Library/Application Support/Paprika/allow-unsigned-peers
```

---

## 문제 해결

```bash
paprikactl status          # 지금 무슨 판단을 하고 있는지
paprikactl helper          # 도우미 연결 상태
paprikactl smc             # 관련 SMC 키 상태
paprikactl smc --all       # 전체 키 열거 (느림)
tail -f /var/log/paprikad.log
log stream --predicate 'subsystem == "com.paprika"' --level info
```

**"충전 제어를 사용할 수 없습니다"** → `paprikactl smc` 로 `CH0B`/`CHTE`/`bfF0` 의
`SZ` 열을 본다. 전부 0 이거나 "키 없음"이면 이 기기/펌웨어에서는 SMC 충전 제어가
막혀 있는 것이다. 이건 앱 버그가 아니라 하드웨어·펌웨어 제약이다.

**메뉴바 앱은 떴는데 상한이 안 걸린다** → `paprikactl helper` 로 데몬이 붙었는지 본다.
서명 검증에서 막혔다면 `/var/log/paprikad.log` 에 거절 이유(identifier 포함)가 찍힌다.

**상한을 넘겨서 이미 충전돼 있다** → 충전을 막아도 저절로 내려가지는 않는다.
설정 → 충전 → "상한보다 높으면 어댑터를 끊어 방전"을 켜면 상한까지 내려온다
(지원 기기만).

---

## 알아두어야 할 점

- SMC 는 **문서화되지 않은 영역**이다. 기기·펌웨어에 따라 동작이 다를 수 있다.
- macOS 자체의 배터리 충전 최적화와 동시에 쓰면 서로 간섭할 수 있다. 한쪽만 쓰자.
- Apple Silicon 전용이다. 인텔 맥의 `BCLM` 은 지원하지 않는다.
- 캘리브레이션은 배터리에 부담이 간다. 몇 달에 한 번이면 충분하다.

---

## 검증 상태 (솔직하게)

이 코드는 **리눅스 환경에서 작성되었고, 맥에서 컴파일된 적이 없다.** 그래서 무엇을
확인했고 무엇을 못 했는지 분명히 적어둔다.

```bash
make verify          # 약 3초. 맥에서도 리눅스에서도 돌아간다.
make verify-verbose  # 통과한 단정까지 전부 출력
```

```
검사 지점(단정)   : 454개  (통과 454 / 실패 0)
개별 케이스       : 700,264개
시뮬레이션 tick   : 27,700회
검사 총 횟수      : 728,418회
```

### 어떻게 맥 없이 하드웨어 코드를 검증하나

충전을 켜고 끄는 코드는 틀리면 "충전이 영구히 막힘"이 되는, 이 앱에서 가장 위험한
부분이다. 그런데 그게 IOKit 에 직접 붙어 있으면 맥 밖에서 한 줄도 실행할 수 없다.

그래서 이음새를 하나 뒀다:

```
ChargeHardware  ──▶  SMCAccess (프로토콜)
                        ├── SMCConnection  (실제 앱: IOKit)
                        └── FakeSMC        (검증: 메모리상의 가짜 SMC)
```

`ChargeHardware` 와 `ChargeApplier` 는 프로토콜만 알기 때문에, 검증 하니스가 가짜
SMC 를 끼워서 **앱에 실제로 들어가는 그 코드**를 수십만 번 돌린다. 대체한 것은
`os.Logger` 와 `sysctl` 두 개뿐이다(`Verification/Shims.swift`).

`Scripts/verify.sh` 의 파일 목록이 "맥 없이 검증 가능한 범위"의 정의다.

### 확인한 것

| 대상 | 방법 | 규모 |
|---|---|---|
| 커널 ABI 80바이트 레이아웃 | 메모리에서 필드 오프셋 직접 측정 | `key@0 keyInfo@28 result@40 status@41 data8@42 data32@44 bytes@48` |
| SMC 값 인코딩 | `ui32` LE / `sp78` BE / `flt ` LE, FourCharCode 왕복 | 21개 키 + 101개 퍼센트 값 |
| 충전 제어 값 의미 | `CH0B`=0x02, `CHTE`=`01000000`, `CHIE`=0x08 등 | 20개 단정 |
| 배터리 속성 해석 | Apple Silicon·인텔·빈 딕셔너리·이상값 | 323개 케이스 |
| 설정 정리(`sanitized`) | limit×sail 전수 + 멱등성 | 9,821개 조합 |
| 정책 엔진 시나리오 | 상한·히스테리시스·온도·캘리브레이션·일시중지 등 | 88개 단정 |
| **정책 엔진 안전 불변식** | 11개 불변식 × 전수 스윕 | **688,800개 조합** |
| 백엔드 탐지 | 기기 6종(껍데기 키·폭 불일치 포함) | 41개 단정 |
| **SMC 쓰기 바이트** | 어떤 값이 어떤 키에 쓰였는지 바이트 단위 | 58개 단정 |
| 판단 → 하드웨어 매핑 | 기기 6종 × 동작 4가지 × 목표 5가지 | 120개 조합 |
| 쓰기 멱등성 | 2회차에는 SMC 를 건드리지 않는가 | 100개 조합 |
| **복구(`restoreDefaults`)** | 도달 가능한 모든 상태에서 충전이 되살아나는가 | 240개 조합 |
| **폐루프 시뮬레이션** | 실제 정책+실제 적용+가짜 SMC 를 이어서 돌림 | 27,700 tick |
| 셸 스크립트 / plist | `bash -n`, `plistlib` | — |
| 전체 Swift 파일 | `swiftc -parse` | 51개 파일 |

전수 스윕에서 확인하는 안전 불변식(하나라도 깨지면 실패):

1. 전원이 빠져 있으면 강제 방전하지 않는다
2. 미지원 기기에서는 SMC 를 건드리지 않는다
3. 관리를 끄면 절대 개입하지 않는다
4. 어댑터 제어 능력이 없으면 방전을 시도하지 않는다
5. 온도 한계를 넘으면 충전을 허용하지 않는다
6. 재충전 하한 이하면 반드시 충전한다
7. 상한 이상이면 충전하지 않는다
8. 목표값은 항상 20~100% 안에 있다
9. 재충전 하한 ≤ 목표
10. 같은 입력이면 같은 결정 (결정성)
11. 결과를 다시 넣어도 결정이 흔들리지 않는다 (진동 없음)

### 검증이 실제로 찾아낸 것

하니스가 장식이 아니라는 증거로, 찾아서 고친 것들을 적어둔다.

**폐루프 시뮬레이션이 찾은 실제 버그 — 히스테리시스가 무력화되던 문제**

전원이 빠지면 판단은 항상 `allowCharging(onBattery)` 이다(하드웨어를 허용 상태로
둬서 다시 꽂는 순간 바로 충전되게 하려고). 그런데 그때 히스테리시스 래치까지 `true`
로 바꿔버리고 있었다. 결과적으로 **잠깐 들고 나갔다 오는 것만으로** "이미 상한에
도달했다"는 기억이 지워졌다.

상한 80% / 히스테리시스 10% 로 잠깐 뽑아 74% 까지 쓰고 다시 꽂으면, 70% 아래로
내려가길 기다려야 하는데 곧바로 80% 까지 다시 충전했다. 사이클을 아끼려고 만든
기능이 제일 흔한 사용 패턴에서 작동하지 않았던 것이다.

고친 뒤 같은 시뮬레이션(얕은 방전 20회 반복):

```
충전 시작 21회 → 11회 (48% 감소), 회당 깊이 5.8%p → 11.0%p
총 충전량은 그대로 — 정상 상태에서 들어간 전하와 나간 전하는 같다.
히스테리시스가 바꾸는 건 "총량"이 아니라 "횟수"다.
```

이건 한 번의 판단만 보면 절대 보이지 않는다. 여러 tick 을 이어서 돌려야 드러난다.

**독립 코드 리뷰가 찾은 것들** (모두 수정 완료)

- **배터리 읽기 실패 시 충전 억제가 그대로 남던 문제** (가장 중요했다) — 이제 읽기
  실패를 "배터리 없음"으로 정책에 흘려보내 충전을 허용한다. 회귀 검사 있음.
- 언인스톨의 "안전망"이 읽기 전용 `--check` 였던 문제 → `paprikad --restore` 를 새로
  만들어 바이너리를 지우기 전에 호출한다.
- `restoreOnShutdown` 토글 제거 (끌 수 있으면 안 되는 안전장치였다).
- 도우미를 `/usr/local/libexec` → `/Library/PrivilegedHelperTools` 로 이동.
- `launchctl enable` 이 `bootstrap` **뒤에** 있던 순서 버그.
- XPC 재연결 폭주, SMC 키 폭 미검증, `dataSize > 32` 클램프 등.

### 확인하지 못한 것

- **컴파일**. AppKit·SwiftUI·IOKit·Charts·Security 를 쓰는 코드는 맥이 없으면 타입
  검사가 불가능하다. 문법은 통과했고 API 시그니처와 macOS 13 가용성은 한 줄씩
  대조했지만, 처음 `make app` 할 때 오류가 몇 개 나올 가능성은 있다.
- **실제 SMC 쓰기**. 가짜 SMC 는 "내가 이해한 규칙"을 재현한 것이다. 그 이해 자체가
  틀렸다면 하니스는 통과하면서 실제 기기에서만 틀린다. 기기에서 확인하는 방법:

  ```bash
  sudo /Library/PrivilegedHelperTools/com.paprika.helperd --check   # 어떤 방식이 쓰이는지
  paprikactl status    # "하드웨어" 줄이 판단과 일치하는지
  paprikactl smc       # 키가 실제로 기대한 값인지
  ```

- UI 렌더링, XPC 연결, launchd 등록. 파프리카 모양이 예쁜지도 봐야 안다. 마음에 안
  들면 `Sources/Paprika/Views/PepperGeometry.swift` 의 제어점 숫자만 만지면 된다.

### 테스트 타깃이 아니라 하니스인 이유

`swift test` 로 돌리는 XCTest 타깃은 `PaprikaKit` 전체를 컴파일해야 하고, 그 안에는
IOKit 을 쓰는 파일이 있어서 리눅스에서는 빌드되지 않는다. 즉 **내가 실행해서 확인할
수 없는 테스트**가 된다.

그래서 플랫폼 독립 소스만 모아 컴파일하는 독립 실행 하니스로 만들었다. 덕분에 맥에서도
리눅스에서도 같은 명령으로 돌아가고, 위 숫자는 내가 실제로 실행해서 얻은 것이다.

---

## 참고 자료

충전 제어 SMC 키의 의미는 아래 프로젝트들의 문서/소스에서 확인했다. **코드를 가져오지
않았고**, 하드웨어 레지스터 동작에 관한 사실만 참고했다. 구현은 전부 새로 썼다.

- [charlie0129/batt](https://github.com/charlie0129/batt) — `CH0B`/`CH0C`/`CHTE`,
  `bfF0`/`bfD0`/`bfE0`, `CH0I`/`CH0J`/`CHIE`, `ACLC`, `dataSize == 0` 껍데기 키 문제
- [killerk3emstar/OpenDente](https://github.com/killerk3emstar/OpenDente) — 신·구
  키 세트 탐지, 80바이트 `SMCParamStruct` 레이아웃
- [zackelia/bclm](https://github.com/zackelia/bclm) — `BCLM`/`CHWA` 배경
- [Apple — 배터리 건강 관리](https://support.apple.com/en-us/102589)

---

## 라이선스

개인용. 마음대로 고쳐 쓰면 된다.
