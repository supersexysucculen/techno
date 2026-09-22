//
//  PolicyChecks.swift
//  Verification
//
//  정책 엔진(ChargePolicy)과 설정 정리(PaprikaConfig.sanitized).
//
//  두 방식으로 확인한다:
//    1. 구체적인 시나리오 단정 — "이 상황에서는 이 결정이 나와야 한다"
//    2. 전수 스윕 + 불변식 — 입력 공간을 훑으면서 "절대 일어나면 안 되는 일"을 찾는다
//
//  2번이 중요한 이유: 1번은 내가 생각해본 경우만 잡는다. 충전을 막는 앱에서
//  위험한 건 내가 생각 못 한 조합이다.
//

import Foundation

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

private func evaluate(
    _ config: PaprikaConfig,
    _ session: SessionState,
    _ inputs: PolicyInputs,
    _ capabilities: HardwareCapabilities
) -> PolicyResult {
    ChargePolicy.evaluate(config: config, session: session, inputs: inputs, capabilities: capabilities)
}

// MARK: - 설정 정리

func runConfigChecks(_ v: Verifier) -> Int {
    var sweptCases = 0

    v.section("설정 정리 (sanitized) 전수 스윕")

    var violations: [String] = []
    for rawLimit in stride(from: -20, through: 140, by: 1) {
        for rawSail in stride(from: -10, through: 50, by: 1) {
            sweptCases += 1
            var config = PaprikaConfig()
            config.limit = rawLimit
            config.sail = rawSail
            let clean = config.sanitized()

            let context = "limit=\(rawLimit) sail=\(rawSail) → \(clean.limit)/\(clean.sail)"

            if clean.limit < 20 || clean.limit > 100 {
                violations.append("상한 범위 이탈: \(context)")
            }
            if clean.sail < 0 || clean.sail > 30 {
                violations.append("히스테리시스 범위 이탈: \(context)")
            }
            // 재충전 하한이 20% 밑으로 내려가면 배터리를 너무 비운다.
            if clean.resumeThreshold < 20 {
                violations.append("재충전 하한 20% 미만: \(context) → \(clean.resumeThreshold)")
            }
            if clean.resumeThreshold > clean.limit {
                violations.append("재충전 하한 > 상한: \(context)")
            }
            // sanitized 는 멱등이어야 한다.
            if clean.sanitized() != clean {
                violations.append("멱등성 위반: \(context)")
            }
        }
    }
    v.sweep("limit×sail 전수 (범위·하한·멱등성)", cases: sweptCases, violations: violations)

    // 나머지 필드 클램프
    var wild = PaprikaConfig()
    wild.temperatureLimit = 999
    wild.temperatureHysteresis = 999
    wild.dischargeTolerance = 999
    wild.calibrationFloor = 999
    wild.calibrationSettleMinutes = 99_999
    wild.pollInterval = 0.001
    let clamped = wild.sanitized()
    v.close("온도 상한 클램프", clamped.temperatureLimit, 55)
    v.close("온도 히스테리시스 클램프", clamped.temperatureHysteresis, 10)
    v.equal("방전 여유 클램프", clamped.dischargeTolerance, 20)
    v.equal("캘리브레이션 하한 클램프", clamped.calibrationFloor, 30)
    v.equal("유지 시간 클램프", clamped.calibrationSettleMinutes, 360)
    v.close("폴링 주기 클램프", clamped.pollInterval, 2)

    var tiny = PaprikaConfig()
    tiny.temperatureLimit = -100
    tiny.temperatureHysteresis = -5
    tiny.dischargeTolerance = -5
    tiny.calibrationFloor = -5
    tiny.calibrationSettleMinutes = -5
    tiny.pollInterval = 9999
    let raised = tiny.sanitized()
    v.close("온도 하한 클램프", raised.temperatureLimit, 25)
    v.close("온도 히스테리시스 하한", raised.temperatureHysteresis, 1)
    v.equal("방전 여유 하한", raised.dischargeTolerance, 0)
    v.equal("캘리브레이션 하한의 하한", raised.calibrationFloor, 3)
    v.equal("유지 시간 하한", raised.calibrationSettleMinutes, 0)
    v.close("폴링 주기 상한", raised.pollInterval, 60)

    // 기본값이 합리적인가
    let defaults = PaprikaConfig().sanitized()
    v.equal("기본 상한 80%", defaults.limit, 80)
    v.equal("기본 히스테리시스 5%", defaults.sail, 5)
    v.equal("기본 재충전 75%", defaults.resumeThreshold, 75)
    v.expect("기본적으로 관리 켜짐", defaults.managementEnabled)
    v.expect("기본적으로 강제 방전 꺼짐", !defaults.allowForcedDischarge)
    v.expect("기본적으로 온도 보호 켜짐", defaults.temperatureGuardEnabled)
    v.expect("기본적으로 MagSafe LED 제어 꺼짐", !defaults.controlMagSafeLED)
    v.isNil("기본 백엔드는 자동", defaults.forcedBackend)

    // Codable 왕복 (데몬이 디스크에 저장하고 XPC 로 주고받는다)
    do {
        var state = DaemonState()
        state.config = Make.config(limit: 73, sail: 9, discharge: true)
        state.session.fullChargeOnce = true
        state.session.pausedUntil = fixedNow
        state.session.calibration = CalibrationState(
            phase: .settle, startedAt: fixedNow, phaseStartedAt: fixedNow,
            settleUntil: fixedNow.addingTimeInterval(3600)
        )
        let data = try PaprikaCoding.encode(state)
        let decoded = try PaprikaCoding.decode(DaemonState.self, from: data)
        v.equal("DaemonState Codable 왕복 config", decoded.config, state.config)
        v.equal("DaemonState Codable 왕복 session", decoded.session, state.session)
        v.expect("JSON 이 비어 있지 않다", data.count > 100)
    } catch {
        v.expect("DaemonState Codable 왕복", false, "\(error)")
    }

    return sweptCases
}

// MARK: - 구체적 시나리오

func runPolicyScenarioChecks(_ v: Verifier) {
    let caps = Make.capabilities(backend: .classicLegacy)
    let base = Make.config()

    v.section("정책: 상한 기본 동작")
    v.equal("50% 연결", describe(evaluate(base, SessionState(), Make.inputs(percent: 50), caps).decision), "allowCharging/belowTarget")
    v.equal("74% 연결", describe(evaluate(base, SessionState(), Make.inputs(percent: 74), caps).decision), "allowCharging/belowTarget")
    v.equal("80% 연결", describe(evaluate(base, SessionState(), Make.inputs(percent: 80), caps).decision), "inhibitCharging/atTarget")
    v.equal("85% 연결", describe(evaluate(base, SessionState(), Make.inputs(percent: 85), caps).decision), "inhibitCharging/atTarget")
    v.equal("100% 연결", describe(evaluate(base, SessionState(), Make.inputs(percent: 100, full: true), caps).decision), "inhibitCharging/atTarget")
    v.equal("0% 연결", describe(evaluate(base, SessionState(), Make.inputs(percent: 0), caps).decision), "allowCharging/belowTarget")

    v.section("정책: 히스테리시스 래치")
    var held = SessionState(); held.chargingAllowedLatch = false
    var rising = SessionState(); rising.chargingAllowedLatch = true
    v.equal("79% 하강 중", describe(evaluate(base, held, Make.inputs(percent: 79), caps).decision), "inhibitCharging/hysteresisHold")
    v.equal("76% 하강 중", describe(evaluate(base, held, Make.inputs(percent: 76), caps).decision), "inhibitCharging/hysteresisHold")
    v.equal("75% 하강 중 (경계)", describe(evaluate(base, held, Make.inputs(percent: 75), caps).decision), "allowCharging/belowTarget")
    v.equal("75.1% 하강 중", describe(evaluate(base, held, Make.inputs(percent: 75.1), caps).decision), "inhibitCharging/hysteresisHold")
    v.equal("79% 상승 중", describe(evaluate(base, rising, Make.inputs(percent: 79), caps).decision), "allowCharging/belowTarget")
    v.equal("80% 도달 후 래치 off", evaluate(base, rising, Make.inputs(percent: 80), caps).session.chargingAllowedLatch, false)
    v.equal("50% 에서 래치 on", evaluate(base, held, Make.inputs(percent: 50), caps).session.chargingAllowedLatch, true)
    // sail 0 이면 밴드가 없다
    let noSail = Make.config(sail: 0)
    v.equal("sail 0, 79.9%", describe(evaluate(noSail, held, Make.inputs(percent: 79.9), caps).decision), "allowCharging/belowTarget")
    v.equal("sail 0, 80%", describe(evaluate(noSail, held, Make.inputs(percent: 80), caps).decision), "inhibitCharging/atTarget")

    // ── 회귀 검사: 뽑았다 꽂아도 히스테리시스가 살아 있어야 한다.
    //
    // 폐루프 시뮬레이션에서 발견한 버그다. 전원이 빠지면 판단이 항상
    // allowCharging(onBattery) 이라, 그때 래치까지 true 로 바꿔버리면 "이미 상한에
    // 도달했다"는 기억이 사라진다. 그러면 잠깐 들고 나갔다 오는 것만으로
    // 히스테리시스가 무력화되고, 사이클을 아끼려던 목적이 사라진다.
    let sail10 = Make.config(limit: 80, sail: 10)
    var journey = SessionState()
    journey = evaluate(sail10, journey, Make.inputs(percent: 80), caps).session
    v.expect("① 80% 도달 → 래치 off", !journey.chargingAllowedLatch)

    let unplugged = evaluate(sail10, journey, Make.inputs(percent: 74, plugged: false, charging: false), caps)
    v.equal("② 분리 중 판단", describe(unplugged.decision), "allowCharging/onBattery")
    v.expect("② 분리 중에도 래치 유지(off)", !unplugged.session.chargingAllowedLatch)

    let replugged = evaluate(sail10, unplugged.session, Make.inputs(percent: 74), caps)
    v.equal("③ 재연결 74% → 보류", describe(replugged.decision), "inhibitCharging/hysteresisHold")

    let deepened = evaluate(sail10, unplugged.session, Make.inputs(percent: 69), caps)
    v.equal("④ 하한 70% 아래 → 재충전", describe(deepened.decision), "allowCharging/belowTarget")
    v.expect("④ 재충전 시 래치 on", deepened.session.chargingAllowedLatch)
    v.note("래치는 전원이 연결된 동안에만 갱신한다 — 이 4단계가 그 이유다")

    v.section("정책: 전원 분리")
    v.equal("50% 분리", describe(evaluate(base, SessionState(), Make.inputs(percent: 50, plugged: false, charging: false), caps).decision), "allowCharging/onBattery")
    v.equal("95% 분리", describe(evaluate(base, SessionState(), Make.inputs(percent: 95, plugged: false, charging: false), caps).decision), "allowCharging/onBattery")
    v.equal("5% 분리", describe(evaluate(base, SessionState(), Make.inputs(percent: 5, plugged: false, charging: false), caps).decision), "allowCharging/onBattery")
    // 분리 상태에서는 온도가 높아도 충전을 막을 이유가 없다 — 다만 가드는 켜진다
    let hotUnplugged = evaluate(base, SessionState(), Make.inputs(percent: 50, plugged: false, charging: false, temperature: 50), caps)
    v.equal("분리 + 고온", hotUnplugged.decision.action, .inhibitCharging)
    v.note("분리 상태에서도 온도 가드는 동작한다(충전을 허용하지 않음). 꽂는 순간 바로 막힌다.")

    v.section("정책: 온도 보호")
    let hot = evaluate(base, SessionState(), Make.inputs(percent: 50, temperature: 45), caps)
    v.equal("45°C", describe(hot.decision), "inhibitCharging/temperatureGuard")
    v.expect("가드 래치 on", hot.session.temperatureGuardActive)
    v.expect("이벤트 기록", hot.events.contains { $0.kind == .temperatureGuard })
    v.notNil("사용자용 상세 문구", hot.decision.detail)
    let stillHot = evaluate(base, hot.session, Make.inputs(percent: 50, temperature: 38), caps)
    v.equal("38°C (해제선 37 위)", describe(stillHot.decision), "inhibitCharging/temperatureGuard")
    let cooled = evaluate(base, stillHot.session, Make.inputs(percent: 50, temperature: 36), caps)
    v.equal("36°C 해제", describe(cooled.decision), "allowCharging/belowTarget")
    v.expect("가드 래치 off", !cooled.session.temperatureGuardActive)
    v.expect("해제 이벤트", cooled.events.contains { $0.kind == .temperatureGuard })
    v.equal("40.0°C 는 경계 미초과", describe(evaluate(base, SessionState(), Make.inputs(percent: 50, temperature: 40), caps).decision), "allowCharging/belowTarget")
    v.equal("40.1°C 는 초과", describe(evaluate(base, SessionState(), Make.inputs(percent: 50, temperature: 40.1), caps).decision), "inhibitCharging/temperatureGuard")
    v.equal("가드 off 면 50°C 도 충전", describe(evaluate(Make.config(tempGuard: false), SessionState(), Make.inputs(percent: 50, temperature: 50), caps).decision), "allowCharging/belowTarget")
    v.equal("온도 불명(nil)", describe(evaluate(base, SessionState(), Make.inputs(percent: 50, temperature: nil), caps).decision), "allowCharging/belowTarget")
    v.expect("온도 nil 이면 래치 해제", !evaluate(base, hot.session, Make.inputs(percent: 50, temperature: nil), caps).session.temperatureGuardActive)

    v.section("정책: 100% 한 번만 충전")
    var once = SessionState(); once.fullChargeOnce = true
    v.equal("90%", describe(evaluate(base, once, Make.inputs(percent: 90), caps).decision), "allowCharging/fullChargeOnce")
    v.equal("목표는 100", evaluate(base, once, Make.inputs(percent: 90), caps).decision.effectiveTarget, 100)
    v.equal("99.4%", describe(evaluate(base, once, Make.inputs(percent: 99.4), caps).decision), "allowCharging/fullChargeOnce")
    let doneByPercent = evaluate(base, once, Make.inputs(percent: 99.5), caps)
    v.expect("99.5% 에서 예약 해제", !doneByPercent.session.fullChargeOnce)
    let doneByFlag = evaluate(base, once, Make.inputs(percent: 92, full: true), caps)
    v.expect("fullyCharged 플래그로도 해제", !doneByFlag.session.fullChargeOnce)
    v.expect("완료 이벤트", doneByFlag.events.contains { $0.kind == .fullChargeDone })
    v.equal("해제 후 상한 복귀", doneByFlag.decision.effectiveTarget, 80)
    v.equal("예약 중 고온이면 온도 보호가 이긴다", describe(evaluate(base, once, Make.inputs(percent: 90, temperature: 45), caps).decision), "inhibitCharging/temperatureGuard")
    v.equal("예약 중 분리", describe(evaluate(base, once, Make.inputs(percent: 90, plugged: false, charging: false), caps).decision), "allowCharging/onBattery")

    v.section("정책: 강제 방전")
    let dischargeConfig = Make.config(discharge: true)
    v.equal("81% (여유 2 → 82 이하)", describe(evaluate(dischargeConfig, SessionState(), Make.inputs(percent: 81), caps).decision), "inhibitCharging/atTarget")
    v.equal("82% (경계)", describe(evaluate(dischargeConfig, SessionState(), Make.inputs(percent: 82), caps).decision), "inhibitCharging/atTarget")
    v.equal("82.1%", describe(evaluate(dischargeConfig, SessionState(), Make.inputs(percent: 82.1), caps).decision), "forceDischarge/aboveTarget")
    v.equal("95%", describe(evaluate(dischargeConfig, SessionState(), Make.inputs(percent: 95), caps).decision), "forceDischarge/aboveTarget")
    v.equal("어댑터 키 없으면 방전 불가", describe(evaluate(dischargeConfig, SessionState(), Make.inputs(percent: 95), Make.capabilities(backend: .classicLegacy, adapter: .none)).decision), "inhibitCharging/atTarget")
    v.equal("펌웨어 백엔드는 방전 불가", describe(evaluate(dischargeConfig, SessionState(), Make.inputs(percent: 95), Make.capabilities(backend: .firmware)).decision), "inhibitCharging/atTarget")
    v.equal("방전 중 분리되면 그냥 사용", describe(evaluate(dischargeConfig, SessionState(), Make.inputs(percent: 95, plugged: false, charging: false), caps).decision), "allowCharging/onBattery")
    v.equal("방전 중 고온이면 방전 유지 안 함", describe(evaluate(dischargeConfig, SessionState(), Make.inputs(percent: 95, temperature: 45), caps).decision), "inhibitCharging/temperatureGuard")
    v.equal("여유 0 이면 80.1% 부터 방전", describe(evaluate(Make.config(discharge: true, tolerance: 0), SessionState(), Make.inputs(percent: 80.1), caps).decision), "forceDischarge/aboveTarget")

    v.section("정책: 관리하지 않는 경우")
    v.equal("관리 off", describe(evaluate(Make.config(enabled: false), SessionState(), Make.inputs(percent: 95), caps).decision), "unmanaged/managementDisabled")
    v.equal("하드웨어 미지원", describe(evaluate(base, SessionState(), Make.inputs(percent: 95), Make.capabilities(backend: .unsupported, adapter: .none)).decision), "unmanaged/noHardwareSupport")
    v.equal("배터리 없음", describe(evaluate(base, SessionState(), Make.inputs(percent: 0, present: false), caps).decision), "unmanaged/batteryMissing")
    v.equal("관리 off 면 목표 100", evaluate(Make.config(enabled: false), SessionState(), Make.inputs(percent: 95), caps).decision.effectiveTarget, 100)
    var hotSession = SessionState(); hotSession.temperatureGuardActive = true
    v.expect("관리 off 면 온도 래치 정리", !evaluate(Make.config(enabled: false), hotSession, Make.inputs(percent: 50, temperature: 45), caps).session.temperatureGuardActive)

    v.section("정책: 일시 중지")
    var paused = SessionState(); paused.pausedUntil = fixedNow.addingTimeInterval(600)
    let pausedResult = evaluate(base, paused, Make.inputs(percent: 95, now: fixedNow), caps)
    v.equal("중지 중", describe(pausedResult.decision), "unmanaged/pausedByUser")
    v.notNil("남은 시간 표시", pausedResult.decision.detail)
    var expired = SessionState(); expired.pausedUntil = fixedNow.addingTimeInterval(-1)
    let resumedResult = evaluate(base, expired, Make.inputs(percent: 95, now: fixedNow), caps)
    v.equal("중지 만료", describe(resumedResult.decision), "inhibitCharging/atTarget")
    v.isNil("만료 후 정리", resumedResult.session.pausedUntil)
    v.expect("만료 이벤트", resumedResult.events.contains { $0.kind == .info })
    var exactly = SessionState(); exactly.pausedUntil = fixedNow
    v.equal("정확히 만료 시각", describe(evaluate(base, exactly, Make.inputs(percent: 95, now: fixedNow), caps).decision), "inhibitCharging/atTarget")

    v.section("정책: 캘리브레이션 상태 기계")
    var discharging = SessionState()
    discharging.calibration = CalibrationState(phase: .discharge, startedAt: fixedNow, phaseStartedAt: fixedNow)
    v.equal("방전 단계 50%", describe(evaluate(base, discharging, Make.inputs(percent: 50, now: fixedNow), caps).decision), "forceDischarge/calibrationDischarge")
    v.equal("방전 단계, 어댑터 키 없음", describe(evaluate(base, discharging, Make.inputs(percent: 50, now: fixedNow), Make.capabilities(backend: .classicLegacy, adapter: .none)).decision), "inhibitCharging/calibrationDischargeNeedsUnplug")
    v.equal("방전 단계, 펌웨어 백엔드", describe(evaluate(base, discharging, Make.inputs(percent: 50, now: fixedNow), Make.capabilities(backend: .firmware, adapter: .none)).decision), "unmanaged/calibrationDischargeNeedsUnplug")
    v.equal("방전 단계, 이미 분리됨", describe(evaluate(base, discharging, Make.inputs(percent: 50, plugged: false, charging: false, now: fixedNow), caps).decision), "allowCharging/calibrationDischarge")
    let atFloor = evaluate(base, discharging, Make.inputs(percent: 8, now: fixedNow), caps)
    v.equal("하한 8% 도달", describe(atFloor.decision), "allowCharging/calibrationCharge")
    v.equal("단계 전이 → charge", atFloor.session.calibration?.phase, .charge)
    v.expect("전이 이벤트", atFloor.events.contains { $0.kind == .calibrationPhase })
    v.equal("9% 는 아직 방전", evaluate(base, discharging, Make.inputs(percent: 9, now: fixedNow), caps).session.calibration?.phase, .discharge)

    var charging = SessionState()
    charging.calibration = CalibrationState(phase: .charge, startedAt: fixedNow, phaseStartedAt: fixedNow)
    v.equal("충전 단계 60%", describe(evaluate(base, charging, Make.inputs(percent: 60, now: fixedNow), caps).decision), "allowCharging/calibrationCharge")
    v.equal("충전 단계 목표 100", evaluate(base, charging, Make.inputs(percent: 60, now: fixedNow), caps).decision.effectiveTarget, 100)
    let atFull = evaluate(base, charging, Make.inputs(percent: 100, full: true, now: fixedNow), caps)
    v.equal("100% 도달", describe(atFull.decision), "allowCharging/calibrationSettle")
    v.equal("단계 전이 → settle", atFull.session.calibration?.phase, .settle)
    v.notNil("유지 종료 시각 설정", atFull.session.calibration?.settleUntil)

    var settling = SessionState()
    settling.calibration = CalibrationState(
        phase: .settle, startedAt: fixedNow, phaseStartedAt: fixedNow,
        settleUntil: fixedNow.addingTimeInterval(3600)
    )
    v.equal("유지 중", describe(evaluate(base, settling, Make.inputs(percent: 100, full: true, now: fixedNow), caps).decision), "allowCharging/calibrationSettle")
    v.notNil("남은 시간 표시", evaluate(base, settling, Make.inputs(percent: 100, full: true, now: fixedNow), caps).decision.detail)
    let finished = evaluate(base, settling, Make.inputs(percent: 100, full: true, now: fixedNow.addingTimeInterval(3601)), caps)
    v.equal("유지 종료 → 일반 규칙", describe(finished.decision), "inhibitCharging/atTarget")
    v.isNil("캘리브레이션 정리", finished.session.calibration)
    v.expect("완료 이벤트", finished.events.contains { $0.kind == .calibrationFinished })
    v.equal("미지원 기기에서는 캘리브레이션도 unmanaged", describe(evaluate(base, settling, Make.inputs(percent: 100, now: fixedNow), Make.capabilities(backend: .unsupported, adapter: .none)).decision), "unmanaged/noHardwareSupport")

    v.section("정책: 상태 전이 이벤트")
    var wasCharging = SessionState()
    wasCharging.lastAppliedAction = .allowCharging
    wasCharging.chargingAllowedLatch = true
    v.expect("상한 도달 알림", evaluate(base, wasCharging, Make.inputs(percent: 80), caps).events.contains { $0.kind == .limitReached })
    var wasHolding = SessionState()
    wasHolding.lastAppliedAction = .inhibitCharging
    wasHolding.chargingAllowedLatch = false
    v.expect("재충전 알림", evaluate(base, wasHolding, Make.inputs(percent: 60), caps).events.contains { $0.kind == .chargingResumed })
    v.expect("변화 없으면 조용", evaluate(base, wasHolding, Make.inputs(percent: 78), caps).events.isEmpty)
    var wasDischarging = SessionState()
    wasDischarging.lastAppliedAction = .forceDischarge
    wasDischarging.chargingAllowedLatch = false
    v.expect("방전 → 충전 전환 알림", evaluate(base, wasDischarging, Make.inputs(percent: 60), caps).events.contains { $0.kind == .chargingResumed })
    v.expect("알림용 이벤트만 deservesNotification", PaprikaEvent.Kind.limitReached.deservesNotification)
    v.expect("재충전은 알림 대상 아님", !PaprikaEvent.Kind.chargingResumed.deservesNotification)
    v.expect("하드웨어 오류는 문제로 분류", PaprikaEvent.Kind.hardwareError.isProblem)
}

// MARK: - 전수 스윕 + 안전 불변식

func runPolicySweep(_ v: Verifier) -> Int {
    v.section("정책: 전수 스윕 + 안전 불변식")

    let backends: [(ChargeControlBackend, AdapterControlKey)] = [
        (.classicLegacy, .ch0i),
        (.classicLegacy, .none),
        (.tahoeLegacy, .chie),
        (.firmware, .ch0i),
        (.firmware, .none),
        (.unsupported, .none),
    ]
    let limits = [20, 35, 50, 65, 80, 95, 100]
    let sails = [0, 3, 5, 10, 20]
    let temperatures: [Double?] = [nil, 20, 39.9, 40.1, 55]
    let percents: [Double] = stride(from: 0, through: 100, by: 2.5).map { $0 }

    // 불변식별로 위반 사례를 모은다.
    var unpluggedInhibit: [String] = []
    var unsupportedManaged: [String] = []
    var disabledManaged: [String] = []
    var dischargeWithoutCapability: [String] = []
    var hotAllowsCharging: [String] = []
    var belowThresholdNotCharging: [String] = []
    var aboveTargetCharging: [String] = []
    var targetOutOfRange: [String] = []
    var thresholdAboveTarget: [String] = []
    var nondeterministic: [String] = []
    var sessionUnstable: [String] = []
    var cases = 0

    for (backend, adapter) in backends {
        let caps = Make.capabilities(backend: backend, adapter: adapter)
        for limit in limits {
            for sail in sails {
                for managementEnabled in [true, false] {
                    for allowDischarge in [true, false] {
                        let config = Make.config(
                            limit: limit, sail: sail,
                            discharge: allowDischarge,
                            enabled: managementEnabled
                        )
                        for temperature in temperatures {
                            for plugged in [true, false] {
                                for latch in [true, false] {
                                    for percent in percents {
                                        cases += 1
                                        var session = SessionState()
                                        session.chargingAllowedLatch = latch
                                        let inputs = Make.inputs(
                                            percent: percent,
                                            plugged: plugged,
                                            charging: plugged,
                                            temperature: temperature,
                                            now: fixedNow
                                        )
                                        let result = evaluate(config, session, inputs, caps)
                                        let action = result.decision.action
                                        // 위반이 있을 때만 문자열을 만든다.
                                        // 68만 케이스 × 문자열 조립은 그 자체로 몇 초를 잡아먹는다.
                                        func context() -> String {
                                            let adapterName = adapter.rawValue.isEmpty ? "noAdapter" : adapter.rawValue
                                            let tempText = temperature.map { String(format: "%.1f", $0) } ?? "nil"
                                            return "\(backend.rawValue)/\(adapterName) limit=\(limit) sail=\(config.sail) mgmt=\(managementEnabled) dis=\(allowDischarge) temp=\(tempText) plug=\(plugged) latch=\(latch) pct=\(percent) → \(describe(result.decision))"
                                        }

                                        // ── 불변식 1: 전원이 빠져 있으면 어댑터를 끊을 이유가 없다.
                                        if !plugged, action == .forceDischarge {
                                            unpluggedInhibit.append("분리 상태에서 forceDischarge: \(context())")
                                        }

                                        // ── 불변식 2: 하드웨어 미지원이면 절대 관리하지 않는다.
                                        if backend == .unsupported, action != .unmanaged {
                                            unsupportedManaged.append(context())
                                        }

                                        // ── 불변식 3: 관리가 꺼져 있으면 절대 개입하지 않는다.
                                        if managementEnabled == false, backend != .unsupported, action != .unmanaged {
                                            disabledManaged.append(context())
                                        }

                                        // ── 불변식 4: 어댑터 제어가 없으면 강제 방전을 시도하지 않는다.
                                        if action == .forceDischarge {
                                            if !caps.supportsAdapterControl || !caps.supportsFineGrainedControl {
                                                dischargeWithoutCapability.append(context())
                                            }
                                        }

                                        // ── 불변식 5: 온도 한계를 넘으면 충전을 허용하지 않는다.
                                        if managementEnabled, backend != .unsupported,
                                           let temperature, temperature > config.temperatureLimit,
                                           action == .allowCharging || action == .forceDischarge {
                                            hotAllowsCharging.append(context())
                                        }

                                        // ── 불변식 6: 상한 아래이고 재충전 하한 이하면 (온도가 정상이면) 충전한다.
                                        //
                                        //   percent < target 조건이 필요하다. limit=20, sail=0 이면
                                        //   하한과 상한이 모두 20 이라서 20% 는 "하한 이하"이면서 동시에
                                        //   "상한 도달"이다. 이때는 멈추는 게 맞다.
                                        if managementEnabled, backend != .unsupported, plugged,
                                           percent < Double(limit),
                                           percent <= Double(config.resumeThreshold),
                                           (temperature ?? 0) <= config.temperatureLimit,
                                           action != .allowCharging {
                                            belowThresholdNotCharging.append(context())
                                        }

                                        // ── 불변식 7: 상한 이상이면 충전을 허용하지 않는다.
                                        if managementEnabled, backend != .unsupported, plugged,
                                           percent >= Double(limit), limit < 100,
                                           action == .allowCharging {
                                            aboveTargetCharging.append(context())
                                        }

                                        // ── 불변식 8: 목표값이 항상 유효한 범위에 있다.
                                        if result.decision.effectiveTarget < 20 || result.decision.effectiveTarget > 100 {
                                            targetOutOfRange.append(context())
                                        }

                                        // ── 불변식 9: 재충전 하한이 목표를 넘지 않는다.
                                        if result.decision.effectiveResumeThreshold > result.decision.effectiveTarget {
                                            thresholdAboveTarget.append(context())
                                        }

                                        // ── 불변식 10: 같은 입력이면 같은 결정 (결정성)
                                        let again = evaluate(config, session, inputs, caps)
                                        if again.decision != result.decision {
                                            nondeterministic.append(context())
                                        }

                                        // ── 불변식 11: 결과 세션을 다시 넣으면 결정이 흔들리지 않는다.
                                        //     (제어 루프가 매 tick 같은 입력을 보면 값이 진동하면 안 된다)
                                        let settled = evaluate(config, result.session, inputs, caps)
                                        if settled.decision.action != result.decision.action {
                                            sessionUnstable.append("\(context()) → 재평가 \(describe(settled.decision))")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    v.sweep("불변식 1: 분리 상태에서 강제 방전 금지", cases: cases, violations: unpluggedInhibit)
    v.sweep("불변식 2: 미지원 기기는 항상 unmanaged", cases: cases, violations: unsupportedManaged)
    v.sweep("불변식 3: 관리 off 면 항상 unmanaged", cases: cases, violations: disabledManaged)
    v.sweep("불변식 4: 능력 없이 강제 방전 금지", cases: cases, violations: dischargeWithoutCapability)
    v.sweep("불변식 5: 과열 시 충전 허용 금지", cases: cases, violations: hotAllowsCharging)
    v.sweep("불변식 6: 하한 이하면 반드시 충전", cases: cases, violations: belowThresholdNotCharging)
    v.sweep("불변식 7: 상한 이상이면 충전 금지", cases: cases, violations: aboveTargetCharging)
    v.sweep("불변식 8: 목표값 20~100 유지", cases: cases, violations: targetOutOfRange)
    v.sweep("불변식 9: 하한 ≤ 목표", cases: cases, violations: thresholdAboveTarget)
    v.sweep("불변식 10: 결정성", cases: cases, violations: nondeterministic)
    v.sweep("불변식 11: 재평가 안정성(진동 없음)", cases: cases, violations: sessionUnstable)
    v.note("스윕한 조합: \(cases)개 (백엔드 6 × 상한 7 × sail 5 × 관리 2 × 방전 2 × 온도 5 × 연결 2 × 래치 2 × 충전량 41)")

    return cases
}
