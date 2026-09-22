//
//  ChargePolicy.swift
//  PaprikaKit
//
//  "지금 충전을 허용할까?" 를 결정하는 순수 함수.
//
//  IO 를 전혀 하지 않기 때문에 동작을 머리로 따라가기 쉽고, 필요하면 그대로 테스트할
//  수 있다. SMC 를 실제로 건드리는 일은 데몬의 ChargeController 가 한다.
//

import Foundation

public enum ChargeAction: String, Codable, Sendable {
    /// 충전 허용
    case allowCharging
    /// 충전 차단 (플러그는 꽂힌 채, 벽 전기로 구동)
    case inhibitCharging
    /// 어댑터까지 끊어서 배터리로 강제 방전
    case forceDischarge
    /// 관리하지 않음 → 하드웨어를 기본 상태로
    case unmanaged

    public var label: String {
        switch self {
        case .allowCharging: return L.s("충전 중", "Charging")
        case .inhibitCharging: return L.s("충전 보류", "Charging paused")
        case .forceDischarge: return L.s("강제 방전", "Force discharging")
        case .unmanaged: return L.s("관리 안 함", "Not managed")
        }
    }
}

public enum DecisionReason: String, Codable, Sendable {
    case managementDisabled
    case noHardwareSupport
    case pausedByUser
    case onBattery
    case belowTarget
    case atTarget
    case aboveTarget
    case hysteresisHold
    case temperatureGuard
    case fullChargeOnce
    case calibrationDischarge
    case calibrationDischargeNeedsUnplug
    case calibrationCharge
    case calibrationSettle
    case batteryMissing

    public var label: String {
        switch self {
        case .managementDisabled: return L.s("충전 관리가 꺼져 있습니다", "Charge management is off")
        case .noHardwareSupport: return L.s("이 기기에서 충전 제어 키를 찾지 못했습니다", "No charge-control keys on this Mac")
        case .pausedByUser: return L.s("일시 중지 중", "Paused")
        case .onBattery: return L.s("배터리로 사용 중", "Running on battery")
        case .belowTarget: return L.s("상한까지 충전 중", "Charging up to the limit")
        case .atTarget: return L.s("상한에 도달해 충전을 멈췄습니다", "At the limit, charging stopped")
        case .aboveTarget: return L.s("상한보다 높아 방전 중", "Above the limit, discharging")
        case .hysteresisHold: return L.s("사이클을 아끼려고 충전을 보류 중", "Holding to save a charge cycle")
        case .temperatureGuard: return L.s("배터리가 뜨거워 충전을 멈췄습니다", "Too hot — charging paused")
        case .fullChargeOnce: return L.s("이번 한 번만 100% 까지 충전", "Charging to 100% this once")
        case .calibrationDischarge: return L.s("캘리브레이션: 방전 중", "Calibration: discharging")
        case .calibrationDischargeNeedsUnplug: return L.s("캘리브레이션: 전원을 뽑아주세요", "Calibration: please unplug the adapter")
        case .calibrationCharge: return L.s("캘리브레이션: 100% 까지 충전", "Calibration: charging to 100%")
        case .calibrationSettle: return L.s("캘리브레이션: 100% 유지 중", "Calibration: holding at 100%")
        case .batteryMissing: return L.s("배터리를 읽을 수 없습니다", "Cannot read the battery")
        }
    }
}

public struct ChargeDecision: Codable, Equatable, Sendable {
    public var action: ChargeAction
    /// 이번 판단에 실제로 쓰인 목표 충전량(%).
    public var effectiveTarget: Int
    /// 충전 재개 하한(%).
    public var effectiveResumeThreshold: Int
    public var reason: DecisionReason
    /// 사용자에게 보여줄 한 줄 설명(부가 정보).
    public var detail: String?

    public init(
        action: ChargeAction,
        effectiveTarget: Int,
        effectiveResumeThreshold: Int,
        reason: DecisionReason,
        detail: String? = nil
    ) {
        self.action = action
        self.effectiveTarget = effectiveTarget
        self.effectiveResumeThreshold = effectiveResumeThreshold
        self.reason = reason
        self.detail = detail
    }
}

public struct PolicyInputs: Sendable {
    public var percent: Double
    public var isPluggedIn: Bool
    public var isCharging: Bool
    public var fullyCharged: Bool
    public var batteryPresent: Bool
    public var temperature: Double?
    public var now: Date

    public init(
        percent: Double,
        isPluggedIn: Bool,
        isCharging: Bool,
        fullyCharged: Bool,
        batteryPresent: Bool,
        temperature: Double?,
        now: Date = Date()
    ) {
        self.percent = percent
        self.isPluggedIn = isPluggedIn
        self.isCharging = isCharging
        self.fullyCharged = fullyCharged
        self.batteryPresent = batteryPresent
        self.temperature = temperature
        self.now = now
    }

    public init(battery: BatteryInfo, now: Date = Date()) {
        self.percent = battery.precisePercent > 0 ? battery.precisePercent : battery.percent
        self.isPluggedIn = battery.isPluggedIn
        self.isCharging = battery.isCharging
        self.fullyCharged = battery.fullyCharged
        self.batteryPresent = battery.batteryInstalled
        self.temperature = battery.temperature
        self.now = now
    }
}

public struct PolicyResult: Sendable {
    public var decision: ChargeDecision
    /// 상태 전이가 있었으면 갱신된 세션.
    public var session: SessionState
    /// 사용자에게 알릴 만한 사건들.
    public var events: [PaprikaEvent]
}

public enum ChargePolicy {

    /// 현재 상황을 보고 다음 동작을 결정한다.
    ///
    /// 판단 순서:
    ///   1. 관리 off / 하드웨어 미지원 / 배터리 없음 → 손대지 않음
    ///   2. 일시 중지 → 손대지 않음
    ///   3. 캘리브레이션 진행 중이면 그 단계의 규칙을 따름
    ///   4. 아니면 상한 + 히스테리시스 규칙
    ///   5. 마지막에 온도 보호를 덮어씀 (안전이 우선)
    public static func evaluate(
        config: PaprikaConfig,
        session incomingSession: SessionState,
        inputs: PolicyInputs,
        capabilities: HardwareCapabilities
    ) -> PolicyResult {
        var session = incomingSession
        var events: [PaprikaEvent] = []

        // --- 1. 관리하지 않는 경우들 -------------------------------------------
        if !capabilities.isUsable {
            return PolicyResult(
                decision: ChargeDecision(
                    action: .unmanaged,
                    effectiveTarget: 100,
                    effectiveResumeThreshold: 100,
                    reason: .noHardwareSupport
                ),
                session: session,
                events: events
            )
        }

        if !config.managementEnabled {
            if session.temperatureGuardActive {
                session.temperatureGuardActive = false
            }
            return PolicyResult(
                decision: ChargeDecision(
                    action: .unmanaged,
                    effectiveTarget: 100,
                    effectiveResumeThreshold: 100,
                    reason: .managementDisabled
                ),
                session: session,
                events: events
            )
        }

        if !inputs.batteryPresent {
            return PolicyResult(
                decision: ChargeDecision(
                    action: .unmanaged,
                    effectiveTarget: 100,
                    effectiveResumeThreshold: 100,
                    reason: .batteryMissing
                ),
                session: session,
                events: events
            )
        }

        // --- 2. 일시 중지 -----------------------------------------------------
        if session.isPaused(at: inputs.now) {
            let remaining = Int((session.pausedUntil?.timeIntervalSince(inputs.now) ?? 0) / 60) + 1
            return PolicyResult(
                decision: ChargeDecision(
                    action: .unmanaged,
                    effectiveTarget: 100,
                    effectiveResumeThreshold: 100,
                    reason: .pausedByUser,
                    detail: L.s("\(remaining)분 후 다시 시작", "resumes in \(remaining) min")
                ),
                session: session,
                events: events
            )
        }
        if session.pausedUntil != nil {
            // 시간이 지났으므로 정리
            session.pausedUntil = nil
            events.append(PaprikaEvent(kind: .info, message: L.s("일시 중지가 끝나 충전 관리를 다시 시작합니다.", "Pause expired — charge management resumed."), percent: inputs.percent))
        }

        // --- 3. 캘리브레이션 ---------------------------------------------------
        if var calibration = session.calibration {
            let outcome = advanceCalibration(
                &calibration,
                config: config,
                inputs: inputs,
                capabilities: capabilities,
                events: &events
            )
            if outcome.finished {
                session.calibration = nil
            } else {
                session.calibration = calibration
            }
            if let decision = outcome.decision {
                var result = PolicyResult(decision: decision, session: session, events: events)
                applyTemperatureGuard(config: config, inputs: inputs, session: &result.session, decision: &result.decision, events: &result.events)
                result.session.chargingAllowedLatch = (result.decision.action == .allowCharging || result.decision.action == .unmanaged)
                return result
            }
            // finished 이고 decision 이 없으면 아래 일반 규칙으로 떨어진다.
        }

        // --- 4. 일반 규칙 -----------------------------------------------------
        let target = session.fullChargeOnce ? 100 : config.limit
        let resumeThreshold = session.fullChargeOnce ? 99 : config.resumeThreshold

        // 100% 한 번만 충전이 끝났는지 확인
        if session.fullChargeOnce, inputs.fullyCharged || inputs.percent >= 99.5 {
            session.fullChargeOnce = false
            events.append(PaprikaEvent(
                kind: .fullChargeDone,
                message: L.s("100% 충전이 끝났습니다. 상한 \(config.limit)% 로 돌아갑니다.", "Reached 100%. Back to the \(config.limit)% limit."),
                percent: inputs.percent
            ))
            return finish(
                decision: ChargeDecision(
                    action: inputs.percent >= Double(config.limit) ? .inhibitCharging : .allowCharging,
                    effectiveTarget: config.limit,
                    effectiveResumeThreshold: config.resumeThreshold,
                    reason: inputs.percent >= Double(config.limit) ? .atTarget : .belowTarget
                ),
                config: config, inputs: inputs, session: &session, events: &events
            )
        }

        // 플러그가 빠져 있으면 하드웨어는 "허용" 상태로 두는 게 안전하다.
        // (다음에 꽂자마자 충전이 시작되고, 제어 루프가 곧바로 다시 판단한다)
        guard inputs.isPluggedIn else {
            return finish(
                decision: ChargeDecision(
                    action: .allowCharging,
                    effectiveTarget: target,
                    effectiveResumeThreshold: resumeThreshold,
                    reason: .onBattery
                ),
                config: config, inputs: inputs, session: &session, events: &events
            )
        }

        if session.fullChargeOnce {
            return finish(
                decision: ChargeDecision(
                    action: .allowCharging,
                    effectiveTarget: 100,
                    effectiveResumeThreshold: 99,
                    reason: .fullChargeOnce
                ),
                config: config, inputs: inputs, session: &session, events: &events
            )
        }

        let canDischarge = config.allowForcedDischarge
            && capabilities.supportsAdapterControl
            && capabilities.supportsFineGrainedControl

        let decision: ChargeDecision
        if canDischarge, inputs.percent > Double(target + config.dischargeTolerance) {
            decision = ChargeDecision(
                action: .forceDischarge,
                effectiveTarget: target,
                effectiveResumeThreshold: resumeThreshold,
                reason: .aboveTarget,
                detail: L.s(
                    "\(target)% 까지 어댑터를 끊고 방전합니다",
                    "Adapter off until \(target)%"
                )
            )
        } else if inputs.percent >= Double(target) {
            decision = ChargeDecision(
                action: .inhibitCharging,
                effectiveTarget: target,
                effectiveResumeThreshold: resumeThreshold,
                reason: .atTarget
            )
        } else if inputs.percent <= Double(resumeThreshold) {
            decision = ChargeDecision(
                action: .allowCharging,
                effectiveTarget: target,
                effectiveResumeThreshold: resumeThreshold,
                reason: .belowTarget
            )
        } else {
            // (resumeThreshold, target) 구간 — 이전 상태를 유지한다.
            // 상한에서 내려온 경우라면 충전을 다시 시작하지 않고 버티는 게 목적.
            let keepCharging = session.chargingAllowedLatch
            decision = ChargeDecision(
                action: keepCharging ? .allowCharging : .inhibitCharging,
                effectiveTarget: target,
                effectiveResumeThreshold: resumeThreshold,
                reason: keepCharging ? .belowTarget : .hysteresisHold,
                detail: keepCharging ? nil : L.s(
                    "\(resumeThreshold)% 아래로 내려가면 다시 충전합니다",
                    "Resumes below \(resumeThreshold)%"
                )
            )
        }

        return finish(decision: decision, config: config, inputs: inputs, session: &session, events: &events)
    }

    // MARK: - 마무리 (온도 보호 + 래치 갱신 + 이벤트)

    private static func finish(
        decision: ChargeDecision,
        config: PaprikaConfig,
        inputs: PolicyInputs,
        session: inout SessionState,
        events: inout [PaprikaEvent]
    ) -> PolicyResult {
        var finalDecision = decision
        applyTemperatureGuard(
            config: config,
            inputs: inputs,
            session: &session,
            decision: &finalDecision,
            events: &events
        )

        // 상태 전이 이벤트
        if let previous = session.lastAppliedAction, previous != finalDecision.action {
            switch finalDecision.action {
            case .inhibitCharging where finalDecision.reason == .atTarget:
                events.append(PaprikaEvent(
                    kind: .limitReached,
                    message: L.s(
                        "\(finalDecision.effectiveTarget)% 에 도달해 충전을 멈췄습니다.",
                        "Reached \(finalDecision.effectiveTarget)% — charging stopped."
                    ),
                    percent: inputs.percent
                ))
            case .allowCharging where previous == .inhibitCharging || previous == .forceDischarge:
                events.append(PaprikaEvent(
                    kind: .chargingResumed,
                    message: L.s("다시 충전을 시작합니다.", "Charging resumed."),
                    percent: inputs.percent
                ))
            default:
                break
            }
        }

        // 히스테리시스 래치는 **전원이 연결된 동안에만** 갱신한다.
        //
        // 왜: 전원이 빠지면 판단은 항상 .allowCharging(onBattery) 이다(하드웨어를
        // 허용 상태로 둬서 다시 꽂는 순간 바로 충전되게 하려고). 그때 래치까지
        // true 로 바꿔버리면 "상한에 이미 도달했다"는 기억이 지워진다.
        //
        // 그러면 예컨대 상한 80 / 히스테리시스 10 에서 잠깐 뽑아 74% 까지 쓰고 다시
        // 꽂았을 때, 70% 아래로 내려가길 기다리지 않고 80% 까지 다시 충전한다.
        // 사이클을 아끼려고 만든 기능이 뽑았다 꽂는 것만으로 무력화되는 셈이다.
        // (이 문제는 폐루프 시뮬레이션에서 발견했다 — Verification/Simulation.swift)
        if inputs.isPluggedIn {
            session.chargingAllowedLatch = (finalDecision.action == .allowCharging || finalDecision.action == .unmanaged)
        }
        return PolicyResult(decision: finalDecision, session: session, events: events)
    }

    /// 온도 보호는 다른 모든 판단을 덮어쓴다. 히스테리시스 래치가 있어서
    /// 임계값 근처에서 깜빡이지 않는다.
    private static func applyTemperatureGuard(
        config: PaprikaConfig,
        inputs: PolicyInputs,
        session: inout SessionState,
        decision: inout ChargeDecision,
        events: inout [PaprikaEvent]
    ) {
        guard config.temperatureGuardEnabled, let temperature = inputs.temperature else {
            session.temperatureGuardActive = false
            return
        }

        let tripPoint = config.temperatureLimit
        let releasePoint = config.temperatureLimit - config.temperatureHysteresis

        if session.temperatureGuardActive {
            if temperature < releasePoint {
                session.temperatureGuardActive = false
                events.append(PaprikaEvent(
                    kind: .temperatureGuard,
                    message: L.s(
                        String(format: "배터리 온도가 %.1f°C 로 내려가 충전을 다시 허용합니다.", temperature),
                        String(format: "Battery cooled to %.1f°C — charging allowed again.", temperature)
                    ),
                    percent: inputs.percent
                ))
            }
        } else if temperature > tripPoint {
            session.temperatureGuardActive = true
            events.append(PaprikaEvent(
                kind: .temperatureGuard,
                message: L.s(
                    String(format: "배터리 온도가 %.1f°C 라서 충전을 멈춥니다.", temperature),
                    String(format: "Battery at %.1f°C — pausing charge.", temperature)
                ),
                percent: inputs.percent
            ))
        }

        guard session.temperatureGuardActive else { return }

        // 강제 방전은 온도를 낮추는 데 도움이 되지 않으므로 유지하지 않는다.
        if decision.action == .allowCharging || decision.action == .forceDischarge {
            decision.action = .inhibitCharging
            decision.reason = .temperatureGuard
            decision.detail = String(
                format: L.s("%.1f°C / 한계 %.0f°C", "%.1f°C / limit %.0f°C"),
                temperature, config.temperatureLimit
            )
        }
    }

    // MARK: - 캘리브레이션 상태 기계

    private struct CalibrationOutcome {
        var decision: ChargeDecision?
        var finished: Bool
    }

    private static func advanceCalibration(
        _ calibration: inout CalibrationState,
        config: PaprikaConfig,
        inputs: PolicyInputs,
        capabilities: HardwareCapabilities,
        events: inout [PaprikaEvent]
    ) -> CalibrationOutcome {
        switch calibration.phase {
        case .discharge:
            if inputs.percent <= Double(config.calibrationFloor) {
                calibration.phase = .charge
                calibration.phaseStartedAt = inputs.now
                events.append(PaprikaEvent(
                    kind: .calibrationPhase,
                    message: L.s(
                        "캘리브레이션: \(config.calibrationFloor)% 까지 방전했습니다. 이제 100% 까지 충전합니다.",
                        "Calibration: discharged to \(config.calibrationFloor)%. Charging to 100% now."
                    ),
                    percent: inputs.percent
                ))
                return CalibrationOutcome(
                    decision: ChargeDecision(
                        action: .allowCharging,
                        effectiveTarget: 100,
                        effectiveResumeThreshold: 99,
                        reason: .calibrationCharge
                    ),
                    finished: false
                )
            }

            guard inputs.isPluggedIn else {
                // 이미 배터리로 돌고 있으니 그냥 두면 된다.
                return CalibrationOutcome(
                    decision: ChargeDecision(
                        action: .allowCharging,
                        effectiveTarget: config.calibrationFloor,
                        effectiveResumeThreshold: config.calibrationFloor,
                        reason: .calibrationDischarge,
                        detail: L.s("\(config.calibrationFloor)% 까지", "down to \(config.calibrationFloor)%")
                    ),
                    finished: false
                )
            }

            if capabilities.supportsAdapterControl, capabilities.supportsFineGrainedControl {
                return CalibrationOutcome(
                    decision: ChargeDecision(
                        action: .forceDischarge,
                        effectiveTarget: config.calibrationFloor,
                        effectiveResumeThreshold: config.calibrationFloor,
                        reason: .calibrationDischarge,
                        detail: L.s("\(config.calibrationFloor)% 까지", "down to \(config.calibrationFloor)%")
                    ),
                    finished: false
                )
            }

            // 어댑터를 못 끊는 기기: 충전만 막고 사용자에게 전원을 뽑으라고 알린다.
            return CalibrationOutcome(
                decision: ChargeDecision(
                    action: capabilities.supportsFineGrainedControl ? .inhibitCharging : .unmanaged,
                    effectiveTarget: config.calibrationFloor,
                    effectiveResumeThreshold: config.calibrationFloor,
                    reason: .calibrationDischargeNeedsUnplug
                ),
                finished: false
            )

        case .charge:
            if inputs.fullyCharged || inputs.percent >= 99.5 {
                calibration.phase = .settle
                calibration.phaseStartedAt = inputs.now
                calibration.settleUntil = inputs.now.addingTimeInterval(
                    Double(config.calibrationSettleMinutes) * 60
                )
                events.append(PaprikaEvent(
                    kind: .calibrationPhase,
                    message: L.s(
                        "캘리브레이션: 100% 도달. \(config.calibrationSettleMinutes)분간 유지합니다.",
                        "Calibration: at 100%. Holding for \(config.calibrationSettleMinutes) min."
                    ),
                    percent: inputs.percent
                ))
            }
            return CalibrationOutcome(
                decision: ChargeDecision(
                    action: .allowCharging,
                    effectiveTarget: 100,
                    effectiveResumeThreshold: 99,
                    reason: calibration.phase == .settle ? .calibrationSettle : .calibrationCharge
                ),
                finished: false
            )

        case .settle:
            let deadline = calibration.settleUntil ?? inputs.now
            if inputs.now >= deadline {
                events.append(PaprikaEvent(
                    kind: .calibrationFinished,
                    message: L.s(
                        "캘리브레이션이 끝났습니다. 상한 \(config.limit)% 로 돌아갑니다.",
                        "Calibration finished. Back to the \(config.limit)% limit."
                    ),
                    percent: inputs.percent
                ))
                return CalibrationOutcome(decision: nil, finished: true)
            }
            let remaining = Int(deadline.timeIntervalSince(inputs.now) / 60) + 1
            return CalibrationOutcome(
                decision: ChargeDecision(
                    action: .allowCharging,
                    effectiveTarget: 100,
                    effectiveResumeThreshold: 99,
                    reason: .calibrationSettle,
                    detail: L.s("\(remaining)분 남음", "\(remaining) min left")
                ),
                finished: false
            )
        }
    }
}
