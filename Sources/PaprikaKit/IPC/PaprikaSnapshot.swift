//
//  PaprikaSnapshot.swift
//  PaprikaKit
//
//  데몬 → 앱으로 넘어가는 "현재 상태 한 장". XPC 로 JSON 으로 보낸다.
//

import Foundation

public struct PaprikaSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var helperVersion: String
    public var battery: BatteryInfo
    public var telemetry: PowerTelemetry
    public var capabilities: HardwareCapabilities
    public var config: PaprikaConfig
    public var session: SessionState
    public var decision: ChargeDecision
    /// 하드웨어에서 되읽은 실제 상태.
    public var hardwareChargingAllowed: Bool
    public var hardwareAdapterEnabled: Bool
    public var firmwareLimit: FirmwareChargeLimit?
    public var magSafeLED: MagSafeLEDState?
    /// 데몬이 시작한 시각.
    public var daemonStartedAt: Date
    /// 마지막으로 발생한 오류(있으면 UI 에 띄운다).
    public var lastError: String?
    public var recentEvents: [PaprikaEvent]

    public init(
        generatedAt: Date = Date(),
        helperVersion: String,
        battery: BatteryInfo,
        telemetry: PowerTelemetry,
        capabilities: HardwareCapabilities,
        config: PaprikaConfig,
        session: SessionState,
        decision: ChargeDecision,
        hardwareChargingAllowed: Bool,
        hardwareAdapterEnabled: Bool,
        firmwareLimit: FirmwareChargeLimit?,
        magSafeLED: MagSafeLEDState?,
        daemonStartedAt: Date,
        lastError: String?,
        recentEvents: [PaprikaEvent]
    ) {
        self.generatedAt = generatedAt
        self.helperVersion = helperVersion
        self.battery = battery
        self.telemetry = telemetry
        self.capabilities = capabilities
        self.config = config
        self.session = session
        self.decision = decision
        self.hardwareChargingAllowed = hardwareChargingAllowed
        self.hardwareAdapterEnabled = hardwareAdapterEnabled
        self.firmwareLimit = firmwareLimit
        self.magSafeLED = magSafeLED
        self.daemonStartedAt = daemonStartedAt
        self.lastError = lastError
        self.recentEvents = recentEvents
    }

    // MARK: 편의 계산값

    /// 하드웨어 상태가 우리 판단과 어긋나 있는지. (어긋나면 다음 tick 에 교정된다)
    public var hardwareMatchesDecision: Bool {
        switch decision.action {
        case .allowCharging, .unmanaged:
            return hardwareChargingAllowed && hardwareAdapterEnabled
        case .inhibitCharging:
            return !hardwareChargingAllowed && hardwareAdapterEnabled
        case .forceDischarge:
            return !hardwareAdapterEnabled
        }
    }

    public var displayPercent: Double {
        battery.precisePercent > 0 ? battery.precisePercent : battery.percent
    }
}

// MARK: - JSON 인코딩 공통 설정

public enum PaprikaCoding {
    public static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T, prettyPrinted: Bool = false) throws -> Data {
        try encoder(prettyPrinted: prettyPrinted).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}
