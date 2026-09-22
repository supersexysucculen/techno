//
//  HardwareChecks.swift
//  Verification
//
//  **실제 ChargeHardware / ChargeApplier 코드**를 가짜 SMC 로 구동한다.
//
//  여기서 확인하는 것이 이 앱에서 가장 위험한 부분이다: 잘못된 바이트를 잘못된 키에
//  쓰면 충전이 영구히 막힌다. 그래서 "어떤 값이 실제로 SMC 에 쓰였는지"를 바이트
//  단위로 확인한다.
//

import Foundation

func runHardwareChecks(_ v: Verifier) -> Int {
    var cases = 0

    // ------------------------------------------------- 백엔드 탐지
    v.section("하드웨어: 백엔드 탐지")

    for profile in MachineProfile.allCases {
        cases += 1
        VerifyLogSink.reset()
        let (_, hardware) = profile.makeHardware()
        let caps = hardware.capabilities
        v.equal("[\(profile.rawValue)] 백엔드", caps.backend, profile.expectedBackend)
        v.equal("[\(profile.rawValue)] 어댑터 키", caps.adapterKey, profile.expectedAdapterKey)
        v.equal("[\(profile.rawValue)] isUsable", caps.isUsable, profile != .unsupported)
        v.equal(
            "[\(profile.rawValue)] 세밀 제어 가능",
            caps.supportsFineGrainedControl,
            profile.expectedBackend.allowsDirectControl
        )
        v.expect("[\(profile.rawValue)] 탐지 결과를 로그에 남김", VerifyLogSink.contains(category: "smc", substring: "backend="))
    }

    // 껍데기 키(dataSize 0)를 "지원됨"으로 오판하지 않는가 — 리뷰에서 지적된 실제 함정
    let (tahoeSMC, tahoeHardware) = MachineProfile.tahoe.makeHardware()
    v.expect("CH0B 껍데기는 usableKeys 에 없음", tahoeHardware.capabilities.usableKeys[SMCKeys.chargeInhibitA] == nil)
    v.notNil("CH0B 껍데기 이유가 진단에 남음", tahoeHardware.capabilities.probeErrors[SMCKeys.chargeInhibitA])
    v.equal("CHTE 는 usableKeys 에 4바이트로", tahoeHardware.capabilities.usableKeys[SMCKeys.chargeInhibitTahoe], 4)
    _ = tahoeSMC

    // 폭이 다른 키도 걸러내는가
    let wrongWidth = FakeSMC()
    wrongWidth.defineWrongWidth(SMCKeys.chargeInhibitTahoe, bytes: 1)  // 4바이트여야 하는데 1바이트
    wrongWidth.define(SMCKeys.chargeInhibitA, type: "hex_", bytes: [0])
    wrongWidth.define(SMCKeys.chargeInhibitB, type: "hex_", bytes: [0])
    let wrongWidthHardware = ChargeHardware(smc: wrongWidth)
    v.equal("폭 틀린 CHTE 는 무시되고 CH0B 선택", wrongWidthHardware.capabilities.backend, .classicLegacy)
    v.notNil("폭 불일치 이유가 진단에 남음", wrongWidthHardware.capabilities.probeErrors[SMCKeys.chargeInhibitTahoe])
    v.expect(
        "진단 문구에 기대 폭이 들어감",
        wrongWidthHardware.capabilities.probeErrors[SMCKeys.chargeInhibitTahoe]?.contains("4") ?? false
    )

    // CH0B 만 있고 CH0C 가 없으면 직접 제어로 쓰지 않아야 한다
    let halfClassic = FakeSMC()
    halfClassic.define(SMCKeys.chargeInhibitA, type: "hex_", bytes: [0])
    let halfHardware = ChargeHardware(smc: halfClassic)
    v.equal("CH0B 만으로는 지원 불가", halfHardware.capabilities.backend, .unsupported)

    // 강제 백엔드
    let (_, bothHardware) = MachineProfile.both.makeHardware()
    v.equal("both 기기 기본은 직접 제어", bothHardware.capabilities.backend, .classicLegacy)
    bothHardware.setForcedBackend(.firmware)
    v.equal("펌웨어로 강제 전환", bothHardware.capabilities.backend, .firmware)
    bothHardware.setForcedBackend(.tahoeLegacy)
    v.equal("불가능한 강제는 무시(자동 탐지 유지)", bothHardware.capabilities.backend, .classicLegacy)
    bothHardware.setForcedBackend(nil)
    v.equal("강제 해제 후 자동", bothHardware.capabilities.backend, .classicLegacy)

    // ------------------------------------------------- 바이트 단위 쓰기
    v.section("하드웨어: SMC 쓰기 바이트 검증")

    // classic: CH0B/CH0C 에 0x02/0x00
    do {
        let (smc, hardware) = MachineProfile.classic.makeHardware()
        smc.resetObservations()
        let changed = try hardware.setCharging(allowed: false)
        v.expect("classic 차단 시 변경 발생", changed)
        v.equal("CH0B ← 0x02", smc.byte(of: SMCKeys.chargeInhibitA), 0x02)
        v.equal("CH0C ← 0x02", smc.byte(of: SMCKeys.chargeInhibitB), 0x02)
        v.equal("두 키 모두 기록", smc.writeCount, 2)
        v.expect("차단 상태 되읽기", !(try hardware.isChargingAllowed()))

        smc.resetObservations()
        let again = try hardware.setCharging(allowed: false)
        v.expect("이미 차단이면 다시 쓰지 않음", !again)
        v.equal("추가 쓰기 없음", smc.writeCount, 0)

        smc.resetObservations()
        _ = try hardware.setCharging(allowed: true)
        v.equal("CH0B ← 0x00", smc.byte(of: SMCKeys.chargeInhibitA), 0x00)
        v.equal("CH0C ← 0x00", smc.byte(of: SMCKeys.chargeInhibitB), 0x00)
        v.expect("허용 상태 되읽기", try hardware.isChargingAllowed())

        // 두 키가 어긋난 상태(CH0B=0x02, CH0C=0x00)는 반드시 교정해야 한다
        try smc.write(SMCKeys.chargeInhibitA, bytes: [0x02])
        smc.resetObservations()
        let repaired = try hardware.setCharging(allowed: false)
        v.expect("키가 어긋나면 다시 쓴다", repaired)
        v.equal("교정 후 CH0C", smc.byte(of: SMCKeys.chargeInhibitB), 0x02)
    } catch {
        v.expect("classic 쓰기 검증", false, "\(error)")
    }

    // tahoe: CHTE 4바이트
    do {
        let (smc, hardware) = MachineProfile.tahoe.makeHardware()
        smc.resetObservations()
        _ = try hardware.setCharging(allowed: false)
        v.equal("CHTE ← 01 00 00 00", smc.bytes(of: SMCKeys.chargeInhibitTahoe), [0x01, 0x00, 0x00, 0x00])
        v.expect("차단 되읽기", !(try hardware.isChargingAllowed()))
        _ = try hardware.setCharging(allowed: true)
        v.equal("CHTE ← 00 00 00 00", smc.bytes(of: SMCKeys.chargeInhibitTahoe), [0x00, 0x00, 0x00, 0x00])
        v.expect("허용 되읽기", try hardware.isChargingAllowed())
        smc.resetObservations()
        _ = try hardware.setCharging(allowed: true)
        v.equal("중복 쓰기 없음", smc.writeCount, 0)
    } catch {
        v.expect("tahoe 쓰기 검증", false, "\(error)")
    }

    // 어댑터: CH0I=0x01, CHIE=0x08 (값이 다르다!)
    do {
        let (classicSMC, classicHardware) = MachineProfile.classic.makeHardware()
        _ = try classicHardware.setAdapter(enabled: false)
        v.equal("CH0I ← 0x01", classicSMC.byte(of: SMCKeys.adapterInhibitA), 0x01)
        v.expect("어댑터 차단 되읽기", !(try classicHardware.isAdapterEnabled()))
        _ = try classicHardware.setAdapter(enabled: true)
        v.equal("CH0I ← 0x00", classicSMC.byte(of: SMCKeys.adapterInhibitA), 0x00)

        let (tahoeSMC2, tahoeHardware2) = MachineProfile.tahoe.makeHardware()
        _ = try tahoeHardware2.setAdapter(enabled: false)
        v.equal("CHIE ← 0x08 (0x01 아님!)", tahoeSMC2.byte(of: SMCKeys.adapterInhibitTahoe), 0x08)
        v.expect("CHIE 차단 되읽기", !(try tahoeHardware2.isAdapterEnabled()))
        _ = try tahoeHardware2.setAdapter(enabled: true)
        v.equal("CHIE ← 0x00", tahoeSMC2.byte(of: SMCKeys.adapterInhibitTahoe), 0x00)
    } catch {
        v.expect("어댑터 쓰기 검증", false, "\(error)")
    }

    // 어댑터 키가 없는 기기
    do {
        let (_, hardware) = MachineProfile.noAdapter.makeHardware()
        v.expect("어댑터 키 없으면 enabled 로 보고", try hardware.isAdapterEnabled())
        let changed = try hardware.setAdapter(enabled: true)
        v.expect("어댑터 켜기 요청은 무해하게 무시", !changed)
        var threw = false
        do { _ = try hardware.setAdapter(enabled: false) } catch { threw = true }
        v.expect("어댑터 끄기 요청은 오류", threw)
    } catch {
        v.expect("어댑터 없는 기기 검증", false, "\(error)")
    }

    // 펌웨어 제한: 쓰기 순서와 리틀엔디언 퍼센트
    do {
        let (smc, hardware) = MachineProfile.firmwareOnly.makeHardware()
        smc.resetObservations()
        let changed = try hardware.setFirmwareLimit(lower: 75, upper: 80)
        v.expect("펌웨어 제한 설정됨", changed)
        v.equal("bfD0 ← 80 (리틀엔디언)", smc.bytes(of: SMCKeys.firmwareLimitUpper), [80, 0, 0, 0])
        v.equal("bfE0 ← 75", smc.bytes(of: SMCKeys.firmwareLimitLower), [75, 0, 0, 0])
        v.equal("bfF0 ← 0x02 (활성)", smc.byte(of: SMCKeys.firmwareLimitActivation), 0x02)

        // 펌웨어가 요구하는 순서: 비활성 → 상한 → 하한 → 활성
        let order = smc.writeLog.map(\.key)
        v.equal("쓰기 순서", order, [
            SMCKeys.firmwareLimitActivation,
            SMCKeys.firmwareLimitUpper,
            SMCKeys.firmwareLimitLower,
            SMCKeys.firmwareLimitActivation,
        ])
        v.equal("첫 쓰기는 비활성화", smc.writeLog.first?.bytes, [0x00])

        let limit = try hardware.firmwareLimit()
        v.expect("되읽기: 활성", limit.active)
        v.equal("되읽기: 상한", limit.upper, 80)
        v.equal("되읽기: 하한", limit.lower, 75)

        smc.resetObservations()
        let again = try hardware.setFirmwareLimit(lower: 75, upper: 80)
        v.expect("같은 값이면 다시 쓰지 않음", !again)
        v.equal("추가 쓰기 없음", smc.writeCount, 0)

        _ = try hardware.disableFirmwareLimit()
        v.equal("bfF0 ← 0x00", smc.byte(of: SMCKeys.firmwareLimitActivation), 0x00)
        v.expect("되읽기: 비활성", !(try hardware.firmwareLimit().active))
        smc.resetObservations()
        v.expect("이미 비활성이면 쓰지 않음", !(try hardware.disableFirmwareLimit()))

        // 펌웨어 백엔드에서는 직접 제어를 시도하면 안 된다
        var threw = false
        do { _ = try hardware.setCharging(allowed: false) } catch { threw = true }
        v.expect("펌웨어 백엔드에서 setCharging 은 오류", threw)
    } catch {
        v.expect("펌웨어 제한 검증", false, "\(error)")
    }

    // 펌웨어 제한 값 범위 전수 확인
    do {
        let (smc, hardware) = MachineProfile.firmwareOnly.makeHardware()
        var violations: [String] = []
        for upper in stride(from: 0, through: 120, by: 1) {
            for lower in [-5, 0, upper - 10, upper - 1, upper, upper + 5] {
                cases += 1
                _ = try? hardware.disableFirmwareLimit()
                _ = try? hardware.setFirmwareLimit(lower: lower, upper: upper)
                guard let writtenUpper = smc.bytes(of: SMCKeys.firmwareLimitUpper)?.first,
                      let writtenLower = smc.bytes(of: SMCKeys.firmwareLimitLower)?.first
                else {
                    violations.append("읽을 수 없음 upper=\(upper) lower=\(lower)")
                    continue
                }
                if writtenUpper < 20 || writtenUpper > 100 {
                    violations.append("상한 범위 이탈: 요청 \(upper) → \(writtenUpper)")
                }
                if writtenLower >= writtenUpper {
                    violations.append("하한 ≥ 상한: 요청 \(lower)/\(upper) → \(writtenLower)/\(writtenUpper)")
                }
            }
        }
        v.sweep("펌웨어 제한 값 클램프 전수", cases: 121 * 6, violations: violations)
    }

    // MagSafe LED
    do {
        let (smc, hardware) = MachineProfile.classic.makeHardware()
        for state in MagSafeLEDState.allCases {
            cases += 1
            _ = try hardware.setMagSafeLED(state)
            v.equal("ACLC ← \(state) (0x\(String(state.rawValue, radix: 16)))", smc.byte(of: SMCKeys.magSafeLED), state.rawValue)
            v.equal("되읽기 \(state)", try hardware.magSafeLED(), state)
        }
        // 문서화되지 않은 0x02 는 초록으로 취급한다
        try smc.write(SMCKeys.magSafeLED, bytes: [0x02])
        v.equal("0x02 → green 으로 해석", try hardware.magSafeLED(), .green)
        // LED 가 없는 기기에서는 조용히 무시
        let (_, tahoeHardware3) = MachineProfile.tahoe.makeHardware()
        v.expect("LED 없는 기기에서는 무시", !(try tahoeHardware3.setMagSafeLED(.green)))
    } catch {
        v.expect("MagSafe LED 검증", false, "\(error)")
    }

    // 읽기 실패 시 안전한 쪽으로 기우는가
    v.section("하드웨어: 읽기/쓰기 실패 처리")
    do {
        let (smc, hardware) = MachineProfile.classic.makeHardware()
        _ = try hardware.setCharging(allowed: true)
        smc.failingReads.insert(SMCKeys.chargeInhibitA)
        smc.resetObservations()
        // 되읽기가 실패하면 "이미 맞다"고 가정하지 말고 써야 한다.
        let changed = try hardware.setCharging(allowed: false)
        v.expect("되읽기 실패 시에도 쓴다", changed)
        v.equal("실제로 차단됨", smc.byte(of: SMCKeys.chargeInhibitA), 0x02)
        smc.failingReads.removeAll()
    } catch {
        v.expect("읽기 실패 처리", false, "\(error)")
    }

    do {
        let (smc, hardware) = MachineProfile.classic.makeHardware()
        smc.failingWrites.insert(SMCKeys.chargeInhibitA)
        var threw = false
        do { _ = try hardware.setCharging(allowed: false) } catch { threw = true }
        v.expect("쓰기 실패는 오류로 전달", threw)
    }

    return cases
}

// MARK: - ChargeApplier: 판단 → SMC 상태

func runApplierChecks(_ v: Verifier) -> Int {
    var cases = 0

    v.section("적용: 모든 백엔드 × 모든 동작 조합")

    /// 하드웨어의 관찰 가능한 상태.
    struct HardwareState: Equatable, CustomStringConvertible {
        var chargingAllowed: Bool
        var adapterEnabled: Bool
        var firmwareActive: Bool
        var firmwareUpper: Int
        var firmwareLower: Int

        var description: String {
            "charging=\(chargingAllowed) adapter=\(adapterEnabled) fw=\(firmwareActive ? "\(firmwareLower)-\(firmwareUpper)" : "off")"
        }
    }

    func observe(_ smc: FakeSMC, _ profile: MachineProfile) -> HardwareState {
        let chargingAllowed: Bool
        switch profile.expectedBackend {
        case .classicLegacy:
            chargingAllowed = smc.byte(of: SMCKeys.chargeInhibitA) == 0x00
        case .tahoeLegacy:
            chargingAllowed = smc.bytes(of: SMCKeys.chargeInhibitTahoe) == [0, 0, 0, 0]
        case .firmware, .unsupported:
            chargingAllowed = true
        }
        let adapterKey = profile.expectedAdapterKey
        let adapterEnabled = adapterKey == .none
            ? true
            : (smc.byte(of: adapterKey.rawValue) == 0x00)
        return HardwareState(
            chargingAllowed: chargingAllowed,
            adapterEnabled: adapterEnabled,
            firmwareActive: smc.byte(of: SMCKeys.firmwareLimitActivation) == 0x02,
            firmwareUpper: Int(smc.bytes(of: SMCKeys.firmwareLimitUpper)?.first ?? 0),
            firmwareLower: Int(smc.bytes(of: SMCKeys.firmwareLimitLower)?.first ?? 0)
        )
    }

    let actions: [ChargeAction] = [.allowCharging, .inhibitCharging, .forceDischarge, .unmanaged]
    let targets = [20, 50, 80, 95, 100]

    var violations: [String] = []

    for profile in MachineProfile.allCases {
        for action in actions {
            for target in targets {
                cases += 1
                let (smc, hardware) = profile.makeHardware()
                let decision = ChargeDecision(
                    action: action,
                    effectiveTarget: target,
                    effectiveResumeThreshold: max(0, target - 5),
                    reason: .atTarget
                )
                let result = ChargeApplier.apply(decision: decision, hardware: hardware, controlMagSafeLED: false)
                let state = observe(smc, profile)
                let label = "\(profile.rawValue)/\(action.rawValue)/target=\(target)"

                if let error = result.error {
                    violations.append("\(label): 오류 \(error)")
                    continue
                }

                switch profile.expectedBackend {
                case .unsupported:
                    if result.changed {
                        violations.append("\(label): 미지원인데 SMC 를 건드렸다")
                    }

                case .classicLegacy, .tahoeLegacy:
                    switch action {
                    case .allowCharging, .unmanaged:
                        if !state.chargingAllowed { violations.append("\(label): 충전이 막혀 있다 (\(state))") }
                        if !state.adapterEnabled { violations.append("\(label): 어댑터가 꺼져 있다 (\(state))") }
                    case .inhibitCharging:
                        if state.chargingAllowed { violations.append("\(label): 충전이 허용돼 있다 (\(state))") }
                        if !state.adapterEnabled { violations.append("\(label): 어댑터가 꺼져 있다 (\(state))") }
                    case .forceDischarge:
                        if state.chargingAllowed { violations.append("\(label): 충전이 허용돼 있다 (\(state))") }
                        if profile.expectedAdapterKey != .none, state.adapterEnabled {
                            violations.append("\(label): 어댑터가 켜져 있다 (\(state))")
                        }
                    }
                    // 직접 제어를 쓸 때는 펌웨어 제한이 꺼져 있어야 한다 (서로 싸우지 않게)
                    if state.firmwareActive {
                        violations.append("\(label): 직접 제어인데 펌웨어 제한이 켜져 있다 (\(state))")
                    }

                case .firmware:
                    switch action {
                    case .unmanaged:
                        if state.firmwareActive { violations.append("\(label): unmanaged 인데 제한이 켜져 있다") }
                        if !state.adapterEnabled { violations.append("\(label): 어댑터가 꺼져 있다") }
                    case .allowCharging, .inhibitCharging:
                        if target >= 100 {
                            if state.firmwareActive {
                                violations.append("\(label): 상한 100 인데 제한이 켜져 있다")
                            }
                        } else {
                            if !state.firmwareActive {
                                violations.append("\(label): 제한이 꺼져 있다")
                            }
                            if state.firmwareUpper != target {
                                violations.append("\(label): 상한이 \(state.firmwareUpper) (기대 \(target))")
                            }
                            if state.firmwareLower >= state.firmwareUpper {
                                violations.append("\(label): 하한 ≥ 상한 (\(state))")
                            }
                        }
                        if !state.adapterEnabled { violations.append("\(label): 어댑터가 꺼져 있다") }
                    case .forceDischarge:
                        if profile.expectedAdapterKey != .none, state.adapterEnabled {
                            violations.append("\(label): 어댑터가 켜져 있다")
                        }
                    }
                }
            }
        }
    }
    v.sweep("판단 → 하드웨어 상태 일치", cases: cases, violations: violations)
    v.note("확인한 조합: 기기 \(MachineProfile.allCases.count)종 × 동작 4가지 × 목표 5가지")

    // 멱등성: 같은 판단을 두 번 적용하면 두 번째는 아무것도 쓰지 않아야 한다
    v.section("적용: 멱등성 (불필요한 SMC 쓰기 방지)")
    var idempotencyViolations: [String] = []
    var idempotencyCases = 0
    for profile in MachineProfile.allCases where profile != .unsupported {
        for action in actions {
            for target in targets {
                idempotencyCases += 1
                cases += 1
                let (smc, hardware) = profile.makeHardware()
                let decision = ChargeDecision(
                    action: action, effectiveTarget: target,
                    effectiveResumeThreshold: max(0, target - 5), reason: .atTarget
                )
                _ = ChargeApplier.apply(decision: decision, hardware: hardware, controlMagSafeLED: true)
                smc.resetObservations()
                let second = ChargeApplier.apply(decision: decision, hardware: hardware, controlMagSafeLED: true)
                if second.changed || smc.writeCount > 0 {
                    idempotencyViolations.append(
                        "\(profile.rawValue)/\(action.rawValue)/\(target): 2회차에 \(smc.writeCount)번 씀 \(second.steps)"
                    )
                }
            }
        }
    }
    v.sweep("2회차에는 쓰지 않음", cases: idempotencyCases, violations: idempotencyViolations)

    // MagSafe LED 매핑
    v.section("적용: MagSafe LED 매핑")
    v.equal("충전 중 → 주황", ChargeApplier.magSafeState(for: .allowCharging), .orange)
    v.equal("상한 유지 → 초록", ChargeApplier.magSafeState(for: .inhibitCharging), .green)
    v.equal("강제 방전 → 꺼짐", ChargeApplier.magSafeState(for: .forceDischarge), .off)
    v.equal("관리 안 함 → 시스템 기본", ChargeApplier.magSafeState(for: .unmanaged), .system)
    do {
        let (smc, hardware) = MachineProfile.classic.makeHardware()
        let decision = ChargeDecision(action: .inhibitCharging, effectiveTarget: 80, effectiveResumeThreshold: 75, reason: .atTarget)
        _ = ChargeApplier.apply(decision: decision, hardware: hardware, controlMagSafeLED: true)
        v.equal("LED 제어 on 이면 초록", smc.byte(of: SMCKeys.magSafeLED), MagSafeLEDState.green.rawValue)

        let (smc2, hardware2) = MachineProfile.classic.makeHardware()
        _ = ChargeApplier.apply(decision: decision, hardware: hardware2, controlMagSafeLED: false)
        v.equal("LED 제어 off 면 그대로", smc2.byte(of: SMCKeys.magSafeLED), MagSafeLEDState.system.rawValue)
    }

    // ------------------------------------------------- 복구
    v.section("복구: 모든 상태에서 충전이 다시 허용되는가")

    var restoreViolations: [String] = []
    var restoreCases = 0
    for profile in MachineProfile.allCases {
        for action in actions {
            for target in targets {
                for ledOn in [true, false] {
                    restoreCases += 1
                    cases += 1
                    let (smc, hardware) = profile.makeHardware()
                    // 먼저 임의의 상태로 만든다
                    let decision = ChargeDecision(
                        action: action, effectiveTarget: target,
                        effectiveResumeThreshold: max(0, target - 5), reason: .atTarget
                    )
                    _ = ChargeApplier.apply(decision: decision, hardware: hardware, controlMagSafeLED: ledOn)

                    // 그리고 복구한다 — 이게 실패하면 충전이 영구히 막힌다
                    let failures = hardware.restoreDefaults()
                    let label = "\(profile.rawValue)/\(action.rawValue)/\(target)/led=\(ledOn)"

                    if !failures.isEmpty {
                        restoreViolations.append("\(label): 복구 실패 \(failures)")
                        continue
                    }
                    if profile.expectedBackend.allowsDirectControl {
                        let allowed = (try? hardware.isChargingAllowed()) ?? false
                        if !allowed { restoreViolations.append("\(label): 충전이 여전히 막혀 있다") }
                    }
                    if profile.expectedAdapterKey != .none {
                        let adapterOn = (try? hardware.isAdapterEnabled()) ?? false
                        if !adapterOn { restoreViolations.append("\(label): 어댑터가 여전히 꺼져 있다") }
                    }
                    if profile.expectedBackend == .firmware || profile == .both {
                        let active = (try? hardware.firmwareLimit().active) ?? true
                        if active { restoreViolations.append("\(label): 펌웨어 제한이 여전히 켜져 있다") }
                    }
                    if profile.expectedBackend != .unsupported, hardware.capabilities.hasMagSafeLED {
                        let led = (try? hardware.magSafeLED()) ?? .off
                        if led != .system { restoreViolations.append("\(label): LED 가 \(led)") }
                    }
                    _ = smc
                }
            }
        }
    }
    v.sweep("restoreDefaults 는 항상 충전을 되살린다", cases: restoreCases, violations: restoreViolations)

    // 쓰기가 일부 실패해도 나머지는 복구해야 한다
    do {
        let (smc, hardware) = MachineProfile.classic.makeHardware()
        _ = try hardware.setCharging(allowed: false)
        _ = try hardware.setAdapter(enabled: false)
        // LED 가 이미 기본값이면 복구에서 쓰기를 시도하지 않는다. 먼저 다른 색으로 바꿔둔다.
        _ = try hardware.setMagSafeLED(.green)
        smc.failingWrites.insert(SMCKeys.magSafeLED)
        let failures = hardware.restoreDefaults()
        v.expect("LED 실패는 보고된다", !failures.isEmpty)
        v.expect("그래도 충전은 복구됨", try hardware.isChargingAllowed())
        v.expect("그래도 어댑터는 복구됨", try hardware.isAdapterEnabled())
        v.note("일부 실패해도 중단하지 않고 나머지를 복구한다 — 충전 복구가 최우선")
    } catch {
        v.expect("부분 실패 복구", false, "\(error)")
    }

    // 진단 덤프
    v.section("진단: SMC 덤프")
    do {
        let (_, hardware) = MachineProfile.classic.makeHardware()
        let dump = hardware.dump(includeAllKeys: false)
        v.equal("진단 키 전부 포함", dump.entries.count, SMCKeys.diagnosticKeys.count)
        v.equal("백엔드 기록", dump.capabilities.backend, .classicLegacy)
        let text = dump.plainText()
        v.expect("텍스트에 헤더", text.contains("Paprika SMC dump"))
        v.expect("텍스트에 백엔드", text.contains("backend=classicLegacy"))
        v.expect("텍스트에 CH0B", text.contains("CH0B"))
        v.expect("없는 키는 이유를 남김", dump.entries.contains { $0.error != nil })
        let readable = dump.entries.filter { $0.error == nil }
        v.expect("읽힌 키가 있다", !readable.isEmpty)
        v.expect("읽힌 키에는 hex 가 있다", readable.allSatisfy { $0.hex != nil })

        // Codable 왕복 (XPC 로 앱에 보낸다)
        let data = try PaprikaCoding.encode(dump)
        let decoded = try PaprikaCoding.decode(SMCDump.self, from: data)
        v.equal("덤프 Codable 왕복", decoded.entries.count, dump.entries.count)
        v.equal("덤프 백엔드 유지", decoded.capabilities.backend, dump.capabilities.backend)

        let allKeys = hardware.dump(includeAllKeys: true)
        v.expect("전체 열거는 최소 진단 키 수 이상", allKeys.entries.count >= 1)
    } catch {
        v.expect("진단 덤프", false, "\(error)")
    }

    return cases
}
