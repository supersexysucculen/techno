//
//  Simulation.swift
//  Verification
//
//  폐루프 시뮬레이션.
//
//  지금까지는 "한 번의 판단"을 확인했다. 여기서는 데몬이 실제로 하는 일을 그대로
//  돌린다: 배터리를 읽고 → 정책을 판단하고 → SMC 에 쓰고 → 그 SMC 상태가 다음
//  배터리 상태에 영향을 주고 → 다시 판단한다.
//
//  이게 중요한 이유: 한 번의 판단이 다 맞아도 루프가 진동하거나(충전 on/off 반복),
//  상한을 넘겨 버리거나, 복구되지 않는 상태에 갇힐 수 있다. 그건 여러 tick 을
//  이어서 돌려봐야만 보인다.
//
//  배터리 모델은 단순하지만 방향은 실제와 같다:
//    * 충전 허용 + 전원 연결  → 올라간다
//    * 충전 차단 + 전원 연결  → 그대로 (벽 전기로 구동)
//    * 어댑터 차단 또는 분리  → 내려간다
//

import Foundation

struct SimulationConfig {
    var profile: MachineProfile = .classic
    var config: PaprikaConfig = Make.config()
    var ticks: Int = 2000
    var startPercent: Double = 50
    var chargeRatePerTick: Double = 0.35
    var drainRatePerTick: Double = 0.18
    var startPlugged: Bool = true
    /// tick 번호 → 전원 연결 여부를 바꾸는 이벤트
    var plugEvents: [Int: Bool] = [:]
    /// tick 번호 → 배터리 온도
    var temperatureEvents: [Int: Double] = [:]
    var startTemperature: Double = 30
    /// tick 번호 → 세션 변경 (100% 한 번만 충전 등)
    var sessionEvents: [Int: (inout SessionState) -> Void] = [:]
}

struct SimulationResult {
    var minPercent: Double = 100
    var maxPercent: Double = 0
    var finalPercent: Double = 0
    /// 하드웨어 충전 허용이 꺼짐 → 켜짐으로 바뀐 횟수
    var chargeStarts = 0
    /// 전원을 꽂은 채로 실제로 충전이 시작된 횟수.
    ///
    /// 이게 배터리 수명에 직결되는 숫자다. "충전 허용 플래그"가 아니라 "실제로
    /// 전류가 들어가기 시작한 횟수"를 센다 — 히스테리시스가 줄이려는 대상이다.
    var topUpEvents = 0
    /// 전원을 꽂은 채로 배터리에 들어간 총 충전량(%p).
    var chargeAddedWhilePlugged: Double = 0
    var smcWrites = 0
    var ticksCharging = 0
    var ticksInhibited = 0
    var ticksDischarging = 0
    var ticksUnmanaged = 0
    var errors: [String] = []
    /// 매 tick 검사하는 불변식 위반
    var violations: [String] = []
    var finalHardwareChargingAllowed = true
    var finalHardwareAdapterEnabled = true
    var percentTrace: [Double] = []
}

/// 데몬의 제어 루프를 그대로 재현한다.
func simulate(_ sim: SimulationConfig) -> SimulationResult {
    var result = SimulationResult()
    let (smc, hardware) = sim.profile.makeHardware()

    var session = SessionState()
    var percent = sim.startPercent
    var plugged = sim.startPlugged
    var temperature = sim.startTemperature
    var previousChargingAllowed = true
    var wasChargingLastTick = false
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    for tick in 0..<sim.ticks {
        if let event = sim.plugEvents[tick] { plugged = event }
        if let event = sim.temperatureEvents[tick] { temperature = event }
        if let event = sim.sessionEvents[tick] { event(&session) }

        let now = start.addingTimeInterval(Double(tick) * sim.config.pollInterval)

        // --- 1. 배터리를 읽는다 (실제 파서를 통과시킨다) ---
        let properties = Make.batteryProperties(
            percent: Int(percent.rounded()),
            charging: plugged && previousChargingAllowed && percent < 99.9,
            plugged: plugged,
            full: percent >= 99.9,
            temperatureCenti: Int(temperature * 100)
        )
        var battery = BatteryPropertyParser.parse(properties)
        // 시뮬레이션의 정밀한 값을 쓴다 (정수로 반올림된 값 대신)
        battery.precisePercent = percent
        battery.temperature = temperature
        battery.isPluggedIn = plugged

        // --- 2. 정책을 판단한다 ---
        let policy = ChargePolicy.evaluate(
            config: sim.config,
            session: session,
            inputs: PolicyInputs(battery: battery, now: now),
            capabilities: hardware.capabilities
        )
        session = policy.session

        // --- 3. 하드웨어에 반영한다 ---
        let applied = ChargeApplier.apply(
            decision: policy.decision,
            hardware: hardware,
            controlMagSafeLED: sim.config.controlMagSafeLED
        )
        if let error = applied.error { result.errors.append("tick \(tick): \(error)") }
        if applied.changed { result.smcWrites += 1 }
        session.lastAppliedAction = policy.decision.action

        // --- 4. 하드웨어 상태를 되읽어 배터리에 반영한다 ---
        let chargingAllowed = (try? hardware.isChargingAllowed()) ?? true
        let adapterEnabled = (try? hardware.isAdapterEnabled()) ?? true

        if chargingAllowed, !previousChargingAllowed, plugged {
            result.chargeStarts += 1
        }
        previousChargingAllowed = chargingAllowed

        switch policy.decision.action {
        case .allowCharging: result.ticksCharging += 1
        case .inhibitCharging: result.ticksInhibited += 1
        case .forceDischarge: result.ticksDischarging += 1
        case .unmanaged: result.ticksUnmanaged += 1
        }

        // --- 5. 매 tick 검사하는 불변식 ---
        // 상한 위에서 충전을 허용해서는 안 된다.
        //
        // "상한보다 높다" 자체는 위반이 아니다 — 앱을 켜기 전에 이미 95% 였을 수도
        // 있고, 강제 방전으로 내려오는 중일 수도 있다. 문제가 되는 건 상한을 넘은
        // 상태에서 **더 충전하는 것**이다.
        if sim.config.managementEnabled, plugged, hardware.capabilities.isUsable,
           !session.fullChargeOnce, session.calibration == nil,
           percent > Double(sim.config.limit) + 2.0, chargingAllowed {
            result.violations.append(String(
                format: "tick %d: 상한 %d%% 를 넘었는데 충전이 허용됨 (%.2f%%)",
                tick, sim.config.limit, percent
            ))
        }
        // 전원이 빠져 있으면 하드웨어는 충전을 허용한 상태여야 한다.
        // (그래야 다시 꽂는 순간 바로 충전된다)
        if !plugged, sim.config.managementEnabled, hardware.capabilities.supportsFineGrainedControl,
           session.calibration == nil, temperature <= sim.config.temperatureLimit,
           !chargingAllowed {
            result.violations.append("tick \(tick): 분리 상태인데 충전이 막혀 있다")
        }
        // 어댑터는 강제 방전/캘리브레이션 방전 중에만 꺼져 있어야 한다.
        if !adapterEnabled,
           policy.decision.action != .forceDischarge {
            result.violations.append("tick \(tick): \(policy.decision.action.rawValue) 인데 어댑터가 꺼져 있다")
        }

        // --- 6. 배터리 물리 모델 ---
        let chargingThisTick = plugged && adapterEnabled && chargingAllowed && percent < 99.99
        if chargingThisTick {
            if !wasChargingLastTick { result.topUpEvents += 1 }
            let before = percent
            percent = min(100, percent + sim.chargeRatePerTick)
            result.chargeAddedWhilePlugged += percent - before
        } else if !plugged || !adapterEnabled {
            percent -= sim.drainRatePerTick
        }
        wasChargingLastTick = chargingThisTick
        percent = min(100, max(0, percent))

        result.minPercent = min(result.minPercent, percent)
        result.maxPercent = max(result.maxPercent, percent)
        if tick % max(1, sim.ticks / 200) == 0 { result.percentTrace.append(percent) }
    }

    result.finalPercent = percent
    result.finalHardwareChargingAllowed = (try? hardware.isChargingAllowed()) ?? true
    result.finalHardwareAdapterEnabled = (try? hardware.isAdapterEnabled()) ?? true
    _ = smc
    return result
}

func runSimulations(_ v: Verifier) -> Int {
    var ticks = 0

    // ---------------------------------------------------------- 정상 유지
    v.section("시뮬레이션: 상한 유지 (모든 기기)")

    for profile in MachineProfile.allCases where profile != .unsupported {
        var sim = SimulationConfig()
        sim.profile = profile
        sim.config = Make.config(limit: 80, sail: 5)
        sim.ticks = 1500
        sim.startPercent = 40
        let outcome = simulate(sim)
        ticks += sim.ticks

        v.expect("[\(profile.rawValue)] 오류 없음", outcome.errors.isEmpty, outcome.errors.first ?? "")
        v.sweep("[\(profile.rawValue)] tick 불변식", cases: sim.ticks, violations: outcome.violations)

        if profile.expectedBackend.allowsDirectControl {
            v.expect(
                "[\(profile.rawValue)] 상한 82% 이내 유지",
                outcome.maxPercent <= 82.0,
                String(format: "최고 %.2f%%", outcome.maxPercent)
            )
            v.expect(
                "[\(profile.rawValue)] 하한 아래로 안 떨어짐",
                outcome.minPercent >= 39.9,
                String(format: "최저 %.2f%%", outcome.minPercent)
            )
            v.expect(
                "[\(profile.rawValue)] 상한 근처에 정착",
                outcome.finalPercent >= 74 && outcome.finalPercent <= 82,
                String(format: "최종 %.2f%%", outcome.finalPercent)
            )
            v.expect(
                "[\(profile.rawValue)] 진동하지 않음 (쓰기 < 40회)",
                outcome.smcWrites < 40,
                "쓰기 \(outcome.smcWrites)회"
            )
        }
        v.note("[\(profile.rawValue)] 최종 \(String(format: "%.1f", outcome.finalPercent))% · SMC 쓰기 \(outcome.smcWrites)회 · 충전시작 \(outcome.chargeStarts)회")
    }

    // ------------------------------------------------- 히스테리시스 효과
    v.section("시뮬레이션: 히스테리시스가 충전 시작 횟수를 줄이는가")

    // 상한에 도달한 뒤 배터리를 조금씩 쓰는 상황을 만든다.
    func cyclingSim(sail: Int) -> SimulationResult {
        var sim = SimulationConfig()
        sim.config = Make.config(limit: 80, sail: sail)
        sim.ticks = 4000
        sim.startPercent = 79
        sim.chargeRatePerTick = 0.30
        sim.drainRatePerTick = 0.30
        // 200 tick 마다 잠깐(20 tick) 뽑는다 → 약 6% 씩 얕게 떨어진다.
        //
        // 이 폭이 중요하다. 재충전 하한(sail 10 이면 70%) 아래까지 떨어지면 어차피
        // 양쪽 다 충전하므로 차이가 안 보인다. 실제 사용에서 흔한 "잠깐 들고 갔다
        // 오는" 패턴이 바로 이 얕은 방전이고, 히스테리시스가 노리는 대상이다.
        for tick in stride(from: 100, to: 4000, by: 200) {
            sim.plugEvents[tick] = false
            sim.plugEvents[tick + 20] = true
        }
        return simulate(sim)
    }

    let noSail = cyclingSim(sail: 0)
    let withSail = cyclingSim(sail: 10)
    ticks += 8000

    v.expect("sail 0 오류 없음", noSail.errors.isEmpty, noSail.errors.first ?? "")
    v.expect("sail 10 오류 없음", withSail.errors.isEmpty, withSail.errors.first ?? "")
    v.sweep("sail 0 tick 불변식", cases: 4000, violations: noSail.violations)
    v.sweep("sail 10 tick 불변식", cases: 4000, violations: withSail.violations)
    v.expect(
        "히스테리시스가 충전 시작 횟수를 줄인다",
        withSail.topUpEvents < noSail.topUpEvents,
        "sail 0: \(noSail.topUpEvents)회, sail 10: \(withSail.topUpEvents)회"
    )
    // 총 충전량은 줄지 않는다 — 줄어들 수가 없다.
    //
    // 정상 상태에서는 들어간 전하와 나간 전하가 같다. 히스테리시스가 바꾸는 건
    // "총량"이 아니라 "횟수"다: 얕게 자주 채우는 대신, 깊게 드물게 채운다.
    // 리튬이온 수명은 총 throughput 보다 사이클 횟수에 더 민감하므로 이게 이득이다.
    let depthWithout = noSail.chargeAddedWhilePlugged / Double(max(1, noSail.topUpEvents))
    let depthWith = withSail.chargeAddedWhilePlugged / Double(max(1, withSail.topUpEvents))
    v.expect(
        "한 번에 더 깊게 충전한다",
        depthWith > depthWithout * 1.4,
        String(format: "sail 0: 회당 %.1f%%p, sail 10: 회당 %.1f%%p", depthWithout, depthWith)
    )
    v.close(
        "총 충전량은 보존된다 (에너지 보존)",
        withSail.chargeAddedWhilePlugged,
        noSail.chargeAddedWhilePlugged,
        tolerance: noSail.chargeAddedWhilePlugged * 0.15
    )
    v.expect(
        "그래도 배터리가 고갈되지는 않는다",
        withSail.minPercent >= 60,
        String(format: "최저 %.1f%%", withSail.minPercent)
    )
    v.note(String(
        format: "얕은 방전 20회 반복 — 충전 시작 %d회 → %d회 (%.0f%% 감소), 회당 깊이 %.1f%%p → %.1f%%p",
        noSail.topUpEvents, withSail.topUpEvents,
        (1 - Double(withSail.topUpEvents) / Double(max(1, noSail.topUpEvents))) * 100,
        depthWithout, depthWith
    ))

    // ---------------------------------------------------- 뽑았다 꽂기
    v.section("시뮬레이션: 전원 분리/재연결")

    var unplugSim = SimulationConfig()
    unplugSim.config = Make.config(limit: 80, sail: 5)
    unplugSim.ticks = 1200
    unplugSim.startPercent = 79
    unplugSim.plugEvents = [200: false, 700: true]
    let unplugOutcome = simulate(unplugSim)
    ticks += unplugSim.ticks

    v.expect("오류 없음", unplugOutcome.errors.isEmpty, unplugOutcome.errors.first ?? "")
    v.sweep("tick 불변식", cases: unplugSim.ticks, violations: unplugOutcome.violations)
    v.expect(
        "분리 중에 배터리를 실제로 썼다",
        unplugOutcome.minPercent < 70,
        String(format: "최저 %.2f%%", unplugOutcome.minPercent)
    )
    v.expect(
        "재연결 후 상한까지 회복",
        unplugOutcome.finalPercent >= 79,
        String(format: "최종 %.2f%%", unplugOutcome.finalPercent)
    )
    v.expect("상한 초과 없음", unplugOutcome.maxPercent <= 82, String(format: "최고 %.2f%%", unplugOutcome.maxPercent))

    // ------------------------------------------------------ 온도 보호
    v.section("시뮬레이션: 과열 → 냉각")

    var heatSim = SimulationConfig()
    heatSim.config = Make.config(limit: 90, sail: 5, tempGuard: true, tempLimit: 40)
    heatSim.ticks = 1200
    heatSim.startPercent = 40
    heatSim.temperatureEvents = [100: 48, 600: 30]
    let heatOutcome = simulate(heatSim)
    ticks += heatSim.ticks

    v.expect("오류 없음", heatOutcome.errors.isEmpty, heatOutcome.errors.first ?? "")
    v.sweep("tick 불변식", cases: heatSim.ticks, violations: heatOutcome.violations)
    v.expect("과열 구간에서 충전을 멈췄다", heatOutcome.ticksInhibited > 400, "차단 tick \(heatOutcome.ticksInhibited)")
    v.expect("냉각 후 다시 충전했다", heatOutcome.chargeStarts >= 1, "충전 시작 \(heatOutcome.chargeStarts)회")
    v.expect(
        "과열 중에는 잔량이 늘지 않았다",
        heatOutcome.maxPercent <= 92,
        String(format: "최고 %.2f%%", heatOutcome.maxPercent)
    )
    v.note("과열 480 tick 동안 차단, 냉각 후 재개")

    // --------------------------------------------- 100% 한 번만 충전
    v.section("시뮬레이션: 100% 한 번만 충전 후 자동 복귀")

    var onceSim = SimulationConfig()
    onceSim.config = Make.config(limit: 70, sail: 5)
    onceSim.ticks = 2500
    onceSim.startPercent = 65
    onceSim.sessionEvents = [50: { session in session.fullChargeOnce = true }]
    let onceOutcome = simulate(onceSim)
    ticks += onceSim.ticks

    v.expect("오류 없음", onceOutcome.errors.isEmpty, onceOutcome.errors.first ?? "")
    v.expect(
        "100% 까지 올라갔다",
        onceOutcome.maxPercent >= 99.5,
        String(format: "최고 %.2f%%", onceOutcome.maxPercent)
    )
    v.expect("마지막엔 충전이 막혀 있다", !onceOutcome.finalHardwareChargingAllowed)
    v.expect("어댑터는 켜져 있다", onceOutcome.finalHardwareAdapterEnabled)
    v.note(String(format: "100%%까지 충전 후 %.1f%% 에서 유지 (전원이 계속 연결돼 있으면 내려가지 않는다)", onceOutcome.finalPercent))

    // ------------------------------------------------------ 강제 방전
    v.section("시뮬레이션: 상한 초과 → 강제 방전")

    var dischargeSim = SimulationConfig()
    dischargeSim.config = Make.config(limit: 60, sail: 5, discharge: true, tolerance: 2)
    dischargeSim.ticks = 1500
    dischargeSim.startPercent = 95
    let dischargeOutcome = simulate(dischargeSim)
    ticks += dischargeSim.ticks

    v.expect("오류 없음", dischargeOutcome.errors.isEmpty, dischargeOutcome.errors.first ?? "")
    v.sweep("tick 불변식", cases: dischargeSim.ticks, violations: dischargeOutcome.violations)
    v.expect("방전 동작이 실제로 일어났다", dischargeOutcome.ticksDischarging > 100, "방전 tick \(dischargeOutcome.ticksDischarging)")
    v.expect(
        "상한까지 내려왔다",
        dischargeOutcome.finalPercent <= 62,
        String(format: "최종 %.2f%%", dischargeOutcome.finalPercent)
    )
    v.expect("끝나고 어댑터가 복구됐다", dischargeOutcome.finalHardwareAdapterEnabled)
    v.note(String(format: "95%% → %.1f%% 로 내려왔다 (방전 %d tick)", dischargeOutcome.finalPercent, dischargeOutcome.ticksDischarging))

    // 어댑터 제어가 없는 기기에서 방전을 켜도 사고가 없어야 한다
    var noAdapterSim = dischargeSim
    noAdapterSim.profile = .noAdapter
    let noAdapterOutcome = simulate(noAdapterSim)
    ticks += noAdapterSim.ticks
    v.expect("어댑터 없는 기기: 오류 없음", noAdapterOutcome.errors.isEmpty, noAdapterOutcome.errors.first ?? "")
    v.equal("어댑터 없는 기기: 방전 시도 안 함", noAdapterOutcome.ticksDischarging, 0)
    v.expect("어댑터 없는 기기: 충전은 막아둔다", noAdapterOutcome.ticksInhibited > 1000)

    // ---------------------------------------------------- 캘리브레이션
    v.section("시뮬레이션: 캘리브레이션 전 과정")

    var calibrationSim = SimulationConfig()
    calibrationSim.config = Make.config(limit: 80, sail: 5, discharge: true)
    calibrationSim.config.calibrationFloor = 10
    calibrationSim.config.calibrationSettleMinutes = 5
    calibrationSim.config.pollInterval = 5
    calibrationSim.ticks = 3000
    calibrationSim.startPercent = 60
    calibrationSim.chargeRatePerTick = 0.35
    calibrationSim.drainRatePerTick = 0.35
    calibrationSim.sessionEvents = [
        20: { session in
            session.calibration = CalibrationState(
                phase: .discharge,
                startedAt: Date(timeIntervalSince1970: 1_700_000_100),
                phaseStartedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        },
    ]
    let calibrationOutcome = simulate(calibrationSim)
    ticks += calibrationSim.ticks

    v.expect("오류 없음", calibrationOutcome.errors.isEmpty, calibrationOutcome.errors.first ?? "")
    v.expect(
        "하한 10% 까지 방전했다",
        calibrationOutcome.minPercent <= 10.5,
        String(format: "최저 %.2f%%", calibrationOutcome.minPercent)
    )
    v.expect(
        "그 뒤 100% 까지 충전했다",
        calibrationOutcome.maxPercent >= 99.5,
        String(format: "최고 %.2f%%", calibrationOutcome.maxPercent)
    )
    v.expect("방전 단계가 있었다", calibrationOutcome.ticksDischarging > 100)
    v.expect("충전 단계가 있었다", calibrationOutcome.ticksCharging > 200)
    v.expect("끝나고 어댑터 복구", calibrationOutcome.finalHardwareAdapterEnabled)
    v.note(String(
        format: "60%% → %.1f%% → %.1f%% → 최종 %.1f%%",
        calibrationOutcome.minPercent, calibrationOutcome.maxPercent, calibrationOutcome.finalPercent
    ))

    // ------------------------------------------- 관리 off / 미지원 기기
    v.section("시뮬레이션: 관리 off 와 미지원 기기")

    var offSim = SimulationConfig()
    offSim.config = Make.config(limit: 50, enabled: false)
    offSim.ticks = 800
    offSim.startPercent = 40
    let offOutcome = simulate(offSim)
    ticks += offSim.ticks
    v.expect("관리 off: 오류 없음", offOutcome.errors.isEmpty, offOutcome.errors.first ?? "")
    v.expect("관리 off: 100% 까지 충전된다", offOutcome.finalPercent >= 99.5, String(format: "%.1f%%", offOutcome.finalPercent))
    v.expect("관리 off: 하드웨어는 충전 허용", offOutcome.finalHardwareChargingAllowed)
    v.equal("관리 off: 전부 unmanaged", offOutcome.ticksUnmanaged, offSim.ticks)

    var unsupportedSim = SimulationConfig()
    unsupportedSim.profile = .unsupported
    unsupportedSim.ticks = 500
    unsupportedSim.startPercent = 30
    let unsupportedOutcome = simulate(unsupportedSim)
    ticks += unsupportedSim.ticks
    v.expect("미지원: 오류 없음", unsupportedOutcome.errors.isEmpty, unsupportedOutcome.errors.first ?? "")
    v.equal("미지원: SMC 쓰기 0회", unsupportedOutcome.smcWrites, 0)
    v.equal("미지원: 전부 unmanaged", unsupportedOutcome.ticksUnmanaged, unsupportedSim.ticks)
    v.expect("미지원: 충전을 방해하지 않음", unsupportedOutcome.finalPercent >= 99.5)

    // --------------------------------------- 배터리를 못 읽는 상황
    v.section("시뮬레이션: 배터리 읽기 실패 시 안전 동작")

    // 리뷰에서 잡힌 버그의 재현: 충전을 막아둔 상태에서 배터리를 못 읽게 되면
    // 제한이 풀려야 한다(막힌 채로 남으면 안 된다).
    do {
        let (_, hardware) = MachineProfile.classic.makeHardware()
        let config = Make.config(limit: 80, sail: 5)

        // 1) 80% 에서 충전을 막는다
        var session = SessionState()
        let hot = ChargePolicy.evaluate(
            config: config, session: session,
            inputs: Make.inputs(percent: 85), capabilities: hardware.capabilities
        )
        session = hot.session
        _ = ChargeApplier.apply(decision: hot.decision, hardware: hardware, controlMagSafeLED: false)
        v.expect("먼저 충전이 막힌 상태를 만든다", !((try? hardware.isChargingAllowed()) ?? true))

        // 2) 배터리를 못 읽는다 → 데몬은 batteryInstalled=false 로 정책에 넘긴다
        var missing = BatteryInfo()
        missing.batteryInstalled = false
        let recovery = ChargePolicy.evaluate(
            config: config, session: session,
            inputs: PolicyInputs(battery: missing), capabilities: hardware.capabilities
        )
        v.equal("판단은 unmanaged/batteryMissing", describe(recovery.decision), "unmanaged/batteryMissing")
        _ = ChargeApplier.apply(decision: recovery.decision, hardware: hardware, controlMagSafeLED: false)
        v.expect("충전이 다시 허용됐다", (try? hardware.isChargingAllowed()) ?? false)
        v.expect("어댑터도 켜져 있다", (try? hardware.isAdapterEnabled()) ?? false)
        v.note("리뷰에서 발견된 버그의 회귀 검사 — 읽기 실패가 충전 억제를 고착시키면 안 된다")
    }

    // --------------------------------------- 절전에서 깨어난 뒤 재적용
    v.section("시뮬레이션: 절전 중 SMC 초기화 → 깨어나서 재적용")

    do {
        let (smc, hardware) = MachineProfile.classic.makeHardware()
        let config = Make.config(limit: 80, sail: 5)
        var session = SessionState()

        let decision = ChargePolicy.evaluate(
            config: config, session: session,
            inputs: Make.inputs(percent: 85), capabilities: hardware.capabilities
        )
        session = decision.session
        _ = ChargeApplier.apply(decision: decision.decision, hardware: hardware, controlMagSafeLED: false)
        v.expect("충전 차단 상태", !((try? hardware.isChargingAllowed()) ?? true))

        // 절전 중에 펌웨어가 값을 되돌린 상황을 재현한다
        try? smc.write(SMCKeys.chargeInhibitA, bytes: [0x00])
        try? smc.write(SMCKeys.chargeInhibitB, bytes: [0x00])
        v.expect("절전 후 값이 풀렸다", (try? hardware.isChargingAllowed()) ?? false)

        // 데몬은 깨어나면 다시 tick 을 돈다 → 같은 판단을 다시 적용한다
        let reapplied = ChargeApplier.apply(decision: decision.decision, hardware: hardware, controlMagSafeLED: false)
        v.expect("재적용에서 다시 썼다", reapplied.changed)
        v.expect("다시 차단됐다", !((try? hardware.isChargingAllowed()) ?? true))
        v.note("PowerWatcher 가 깨어남을 감지해 tick 을 돌리는 이유")
    }

    return ticks
}
