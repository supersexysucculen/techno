//
//  BatteryInfo.swift
//  PaprikaKit
//

import Foundation

/// SMC 에서 읽은 전력 흐름 정보. 데몬만 채울 수 있다(SMC 접근 필요).
public struct PowerTelemetry: Codable, Equatable, Sendable {
    public var adapterWatts: Double?
    public var adapterVolts: Double?
    public var adapterAmps: Double?
    public var batteryWatts: Double?
    public var batteryVolts: Double?
    public var batteryAmps: Double?
    public var temperature: Double?
    public var smcChargePercent: Int?
    public var acConnected: Bool?

    public init() {}
}

/// AppleSmartBattery IORegistry 에서 읽은 배터리 상태.
public struct BatteryInfo: Codable, Equatable, Sendable {
    /// 시스템이 보고하는 충전량(%). 보통 정수.
    public var percent: Double = 0
    /// mAh 원시값으로 계산한 소수점 충전량. 히스테리시스 판단에 이걸 쓴다.
    public var precisePercent: Double = 0
    public var isCharging: Bool = false
    public var isPluggedIn: Bool = false
    public var fullyCharged: Bool = false
    public var batteryInstalled: Bool = true

    public var cycleCount: Int = 0
    /// 설계 용량 (mAh)
    public var designCapacity: Int = 0
    /// 현재 최대 용량 (mAh)
    public var nominalCapacity: Int = 0
    /// 현재 잔량 (mAh)
    public var rawCurrentCapacity: Int = 0

    /// °C
    public var temperature: Double?
    /// V
    public var voltage: Double?
    /// A (음수면 방전)
    public var amperage: Double?

    public var adapterWatts: Int?
    public var adapterName: String?

    public var minutesToFull: Int?
    public var minutesToEmpty: Int?

    public var serialNumber: String?

    public init() {}

    /// 배터리 건강도(%) = 현재 최대 용량 / 설계 용량
    public var healthPercent: Double? {
        guard designCapacity > 0, nominalCapacity > 0 else { return nil }
        return Double(nominalCapacity) / Double(designCapacity) * 100
    }

    /// 배터리 쪽 전력(W). 양수면 충전, 음수면 방전.
    public var batteryWatts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }

    public var isDischarging: Bool {
        if let amperage { return amperage < -0.01 }
        return !isCharging && !isPluggedIn
    }
}
