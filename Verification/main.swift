//
//  main.swift
//  Verification
//
//  Paprika 검증 실행기.
//
//      ./Scripts/verify.sh              전체 실행
//      ./Scripts/verify.sh --verbose    통과한 단정도 전부 출력
//
//  이 하니스가 확인하는 것 / 못 하는 것은 README 의 "검증 상태" 절에 적어두었다.
//  요약하면: 여기서 돌아가는 코드는 전부 앱에 실제로 들어가는 코드다(PaprikaLog 와
//  SystemInfo 만 대체). 반대로 SwiftUI/AppKit UI 와 진짜 SMC 쓰기는 확인할 수 없다.
//

import Foundation

let arguments = Set(CommandLine.arguments.dropFirst())
let verbose = arguments.contains("--verbose") || arguments.contains("-v")

// 출력이 섞이지 않게 한다.
setvbuf(stdout, nil, _IOLBF, 0)

// 문구 비교가 로케일에 흔들리지 않도록 한국어로 고정한다.
L.language = .korean

print("""
\u{001B}[1m🫑 Paprika 검증\u{001B}[0m
플랫폼 독립 코드 전부 + 가짜 SMC 로 구동하는 실제 하드웨어 계층.
""")

let clock = Date()
let verifier = Verifier(verbose: verbose)

var sweptCases = 0
var simulatedTicks = 0

sweptCases += runLowLevelChecks(verifier)
sweptCases += runBatteryParserChecks(verifier)
sweptCases += runConfigChecks(verifier)
runPolicyScenarioChecks(verifier)
sweptCases += runPolicySweep(verifier)
sweptCases += runHardwareChecks(verifier)
sweptCases += runApplierChecks(verifier)
simulatedTicks += runSimulations(verifier)

let elapsed = Date().timeIntervalSince(clock)
let passed = verifier.summary(sweptCases: sweptCases, simulatedTicks: simulatedTicks)
print(String(format: "소요 시간: %.2f초", elapsed))

if !passed {
    exit(1)
}

// 확인한 범위를 분명히 적어둔다. 숫자만 크게 보이면 오해를 부른다.
let totalChecks = verifier.total + sweptCases + simulatedTicks
print("""

\u{001B}[1m확인한 범위\u{001B}[0m
  · 검사 총 \(totalChecks)회 — 단정 \(verifier.total)개, 개별 케이스 \(sweptCases)개,
    시뮬레이션 \(simulatedTicks) tick.
  · 여기서 돌아간 코드는 전부 앱에 실제로 들어가는 코드다.
    대체한 것은 os.Logger 와 sysctl 두 개뿐이다(Verification/Shims.swift).

\u{001B}[1m확인하지 못한 범위\u{001B}[0m
  · 실제 SMC 쓰기. 가짜 SMC 는 "우리가 이해한 규칙"을 그대로 재현한 것이므로,
    그 이해 자체가 틀렸다면 여기서는 드러나지 않는다. 실제 기기에서
    `paprikactl status` 로 하드웨어 상태가 판단과 일치하는지 확인해야 한다.
  · SwiftUI/AppKit UI 렌더링, XPC 연결, launchd 등록.
  · 컴파일 자체 — IOKit/AppKit/SwiftUI 를 쓰는 파일은 맥에서만 타입 검사가 된다.
""")
exit(0)
