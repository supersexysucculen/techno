//
//  PaprikaConfig.swift
//  PaprikaKit
//
//  사용자 설정(데몬이 보관하는 쪽). UI 전용 설정은 앱의 UserSettings 에 따로 있다.
//

import Foundation

public struct PaprikaConfig: Codable, Equatable, Sendable {
    /// 충전 관리 자체의 on/off. 끄면 하드웨어를 기본 상태로 되돌린다.
    public var managementEnabled: Bool = true

    /// 충전 상한 (%). 20...100
    public var limit: Int = 80

    /// 히스테리시스 폭(%). 상한에 도달한 뒤 (limit - sail) 아래로 떨어질 때까지
    /// 다시 충전하지 않는다. 충전 사이클을 아끼는 용도.
    public var sail: Int = 5

    /// 상한보다 높을 때 어댑터를 끊어 강제로 방전시킬지.
    public var allowForcedDischarge: Bool = false

    /// 강제 방전을 시작하는 여유값(%). limit + tolerance 를 넘어야 방전한다.
    public var dischargeTolerance: Int = 2

    /// 배터리 온도 보호 사용 여부.
    public var temperatureGuardEnabled: Bool = true

    /// 이 온도(°C)를 넘으면 충전을 잠시 멈춘다.
    public var temperatureLimit: Double = 40

    /// 온도가 (limit - hysteresis) 아래로 내려가야 다시 충전한다.
    public var temperatureHysteresis: Double = 3

    /// 캘리브레이션에서 방전시킬 하한(%).
    public var calibrationFloor: Int = 8

    /// 캘리브레이션 마지막에 100% 로 유지할 시간(분).
    public var calibrationSettleMinutes: Int = 60

    /// 제어 루프 주기(초).
    public var pollInterval: Double = 5

    /// 제어 방식 강제. nil 이면 자동 탐지.
    public var forcedBackend: ChargeControlBackend?

    /// MagSafe LED 색을 상태에 맞춰 바꿀지. (실험적)
    public var controlMagSafeLED: Bool = false

    // 참고: "종료 시 원상복구"는 설정으로 두지 않는다.
    // 끌 수 있게 만들면 데몬이 멈춘 뒤 충전이 영구히 막히는 상태를 사용자가 스스로
    // 만들 수 있고, 그게 이 앱의 최악의 실패 모드다. 항상 복구한다.

    public init() {}

    // MARK: 유효성

    /// 값들을 안전한 범위로 정리한다. 설정을 받을 때마다 통과시킨다.
    public func sanitized() -> PaprikaConfig {
        var copy = self
        copy.limit = max(20, min(100, limit))
        copy.sail = max(0, min(30, sail))
        // sail 이 너무 커서 하한이 20 밑으로 내려가지 않게 한다.
        copy.sail = min(copy.sail, max(0, copy.limit - 20))
        copy.dischargeTolerance = max(0, min(20, dischargeTolerance))
        copy.temperatureLimit = max(25, min(55, temperatureLimit))
        copy.temperatureHysteresis = max(1, min(10, temperatureHysteresis))
        copy.calibrationFloor = max(3, min(30, calibrationFloor))
        copy.calibrationSettleMinutes = max(0, min(360, calibrationSettleMinutes))
        copy.pollInterval = max(2, min(60, pollInterval))
        return copy
    }

    /// 충전을 다시 시작하는 하한(%).
    public var resumeThreshold: Int { max(0, limit - sail) }
}

// MARK: - 실행 중 상태

public struct CalibrationState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// 하한까지 방전
        case discharge
        /// 100% 까지 충전
        case charge
        /// 100% 에서 잠시 유지
        case settle

        public var label: String {
            switch self {
            case .discharge: return L.s("방전 중", "Discharging")
            case .charge: return L.s("완전 충전 중", "Charging to full")
            case .settle: return L.s("100% 유지 중", "Holding at 100%")
            }
        }
    }

    public var phase: Phase
    public var startedAt: Date
    public var phaseStartedAt: Date
    public var settleUntil: Date?

    public init(phase: Phase, startedAt: Date, phaseStartedAt: Date, settleUntil: Date? = nil) {
        self.phase = phase
        self.startedAt = startedAt
        self.phaseStartedAt = phaseStartedAt
        self.settleUntil = settleUntil
    }
}

/// 재부팅해도 이어지길 원하는 "지금 이 순간" 상태.
public struct SessionState: Codable, Equatable, Sendable {
    /// 한 번만 100% 까지 충전하기 (여행 전 등).
    public var fullChargeOnce: Bool = false
    /// 이 시각까지 관리를 쉰다.
    public var pausedUntil: Date?
    public var calibration: CalibrationState?
    /// 온도 보호가 걸려 있는 상태인지(히스테리시스 래치).
    public var temperatureGuardActive: Bool = false
    /// 마지막으로 하드웨어에 반영한 동작.
    public var lastAppliedAction: ChargeAction?
    public var lastAppliedAt: Date?
    /// 마지막으로 충전을 허용한 시점(하드웨어 기준).
    public var chargingAllowedLatch: Bool = true

    public init() {}

    public func isPaused(at date: Date) -> Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > date
    }
}

/// 데몬이 디스크에 저장하는 전체 상태.
public struct DaemonState: Codable, Equatable, Sendable {
    public var config: PaprikaConfig = PaprikaConfig()
    public var session: SessionState = SessionState()
    public var savedAt: Date = Date()

    public init() {}
}
