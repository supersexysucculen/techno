//
//  ChargeHardware.swift
//  PaprikaKit
//
//  SMC 키 뭉치를 "충전을 허용/차단한다" 수준의 의미로 감싸는 계층.
//
//  Apple Silicon 맥북은 펌웨어 세대에 따라 충전 제어 방식이 세 가지다:
//
//   1) firmware     — bfF0 / bfD0 / bfE0. 상·하한을 펌웨어에 알려주면 펌웨어가
//                     알아서 히스테리시스까지 관리한다. 가장 안전하지만 우리가
//                     초 단위로 개입할 수는 없다.
//   2) tahoeLegacy  — CHTE 하나로 충전을 직접 끄고 켠다. (macOS 26 대)
//   3) classicLegacy— CH0B + CH0C. M1~M3 시절 방식.
//
//  어느 것이 있는지는 macOS 버전이 아니라 **키의 실제 사용 가능 여부**로 판단한다.
//  버전으로 추측하면 펌웨어만 업데이트된 기기에서 틀린다.
//

import Foundation

// MARK: - 백엔드 종류

public enum ChargeControlBackend: String, Codable, Sendable {
    case firmware
    case tahoeLegacy
    case classicLegacy
    case unsupported

    public var label: String {
        switch self {
        case .firmware: return L.s("펌웨어 위임 (bfF0/bfD0/bfE0)", "Firmware limit (bfF0/bfD0/bfE0)")
        case .tahoeLegacy: return L.s("직접 제어 (CHTE)", "Direct control (CHTE)")
        case .classicLegacy: return L.s("직접 제어 (CH0B/CH0C)", "Direct control (CH0B/CH0C)")
        case .unsupported: return L.s("지원되지 않음", "Unsupported")
        }
    }

    /// 초 단위로 충전을 켜고 끌 수 있는 방식인지.
    public var allowsDirectControl: Bool {
        self == .tahoeLegacy || self == .classicLegacy
    }
}

public enum AdapterControlKey: String, Codable, Sendable {
    case ch0i = "CH0I"
    case ch0j = "CH0J"
    case chie = "CHIE"
    case none = ""

    var disableValue: UInt8 {
        switch self {
        case .chie: return SMCChargeValues.adapterDisableTahoe
        case .ch0i, .ch0j: return SMCChargeValues.adapterDisable
        case .none: return 0
        }
    }
}

// MARK: - 기능 탐지 결과

public struct HardwareCapabilities: Codable, Equatable, Sendable {
    public var backend: ChargeControlBackend = .unsupported
    public var adapterKey: AdapterControlKey = .none
    public var hasFirmwareLimitKeys: Bool = false
    public var hasDirectKeys: Bool = false
    public var hasMagSafeLED: Bool = false
    public var hasPowerTelemetry: Bool = false
    /// 키 이름 → 데이터 크기. 진단 화면에서 그대로 보여준다.
    public var usableKeys: [String: Int] = [:]
    public var probeErrors: [String: String] = [:]
    public var system: SystemInfo = SystemInfo(
        modelIdentifier: "unknown", chipName: "unknown", isAppleSilicon: false, osVersion: "unknown"
    )

    public var supportsAdapterControl: Bool { adapterKey != .none }

    /// 온도 보호, 100% 한 번만 충전, 캘리브레이션처럼 초 단위 개입이 필요한 기능을
    /// 쓸 수 있는지.
    public var supportsFineGrainedControl: Bool { backend.allowsDirectControl }

    public var isUsable: Bool { backend != .unsupported }

    public init() {}
}

// MARK: - 펌웨어 제한 상태

public struct FirmwareChargeLimit: Equatable, Codable, Sendable {
    public var active: Bool
    public var lower: Int
    public var upper: Int

    public init(active: Bool, lower: Int, upper: Int) {
        self.active = active
        self.lower = lower
        self.upper = upper
    }

    public static let inactive = FirmwareChargeLimit(active: false, lower: 0, upper: 100)
}

// MARK: - 하드웨어 래퍼

public final class ChargeHardware {
    /// 구체적인 SMCConnection 이 아니라 프로토콜에 의존한다.
    /// 덕분에 검증 하니스가 가짜 SMC 를 끼워 이 클래스를 그대로 돌릴 수 있다.
    private let smc: any SMCAccess
    public private(set) var capabilities: HardwareCapabilities

    /// 선택된 백엔드를 강제로 덮어쓰고 싶을 때 사용(설정의 "제어 방식" 항목).
    private var forcedBackend: ChargeControlBackend?

    public init(smc: any SMCAccess, forcedBackend: ChargeControlBackend? = nil) {
        self.smc = smc
        self.forcedBackend = forcedBackend
        self.capabilities = HardwareCapabilities()
        redetect()
    }

    // MARK: 탐지

    public func setForcedBackend(_ backend: ChargeControlBackend?) {
        guard backend != forcedBackend else { return }
        forcedBackend = backend
        redetect()
    }

    public func redetect() {
        var caps = HardwareCapabilities()
        caps.system = SystemInfo.current()

        for key in SMCKeys.probeKeys {
            do {
                let info = try smc.keyInfo(key)
                guard info.isUsable else {
                    caps.probeErrors[key] = L.s(
                        "크기 0 (펌웨어 placeholder — 읽기/쓰기 불가)",
                        "size 0 (firmware placeholder — not readable or writable)"
                    )
                    continue
                }
                // 폭이 기대와 다르면 "지원됨"으로 치지 않는다. 그대로 두면 쓰기마다
                // sizeMismatch 가 터지고 사용자는 이유를 알 수 없다.
                if let expected = SMCKeys.expectedWidths[key], info.dataSize != expected {
                    caps.probeErrors[key] = L.s(
                        "\(info.dataSize)바이트 (\(expected)바이트를 기대) — 이 키는 쓰지 않습니다",
                        "\(info.dataSize) bytes (expected \(expected)) — key not used"
                    )
                    continue
                }
                caps.usableKeys[key] = info.dataSize
            } catch {
                caps.probeErrors[key] = String(describing: error)
            }
        }

        func usable(_ key: String) -> Bool { caps.usableKeys[key] != nil }

        caps.hasFirmwareLimitKeys = usable(SMCKeys.firmwareLimitActivation)
            && usable(SMCKeys.firmwareLimitUpper)
            && usable(SMCKeys.firmwareLimitLower)

        let hasClassic = usable(SMCKeys.chargeInhibitA) && usable(SMCKeys.chargeInhibitB)
        let hasTahoe = usable(SMCKeys.chargeInhibitTahoe)
        caps.hasDirectKeys = hasClassic || hasTahoe

        // 기본 선택 규칙:
        //  직접 제어가 가능하면 그걸 쓴다(기능이 훨씬 많다).
        //  직접 제어가 없고 펌웨어 키만 있으면 펌웨어에 위임한다.
        var detected: ChargeControlBackend
        if hasTahoe {
            detected = .tahoeLegacy
        } else if hasClassic {
            detected = .classicLegacy
        } else if caps.hasFirmwareLimitKeys {
            detected = .firmware
        } else {
            detected = .unsupported
        }

        // 사용자가 강제한 백엔드가 실제로 가능한 경우에만 존중한다.
        if let forced = forcedBackend {
            switch forced {
            case .firmware where caps.hasFirmwareLimitKeys: detected = .firmware
            case .tahoeLegacy where hasTahoe: detected = .tahoeLegacy
            case .classicLegacy where hasClassic: detected = .classicLegacy
            default: break  // 불가능한 요청은 무시
            }
        }
        caps.backend = detected

        if usable(SMCKeys.adapterInhibitA) {
            caps.adapterKey = .ch0i
        } else if usable(SMCKeys.adapterInhibitB) {
            caps.adapterKey = .ch0j
        } else if usable(SMCKeys.adapterInhibitTahoe) {
            caps.adapterKey = .chie
        } else {
            caps.adapterKey = .none
        }

        caps.hasMagSafeLED = usable(SMCKeys.magSafeLED)
        caps.hasPowerTelemetry = usable(SMCKeys.dcInPower) || usable(SMCKeys.batteryPower)

        capabilities = caps

        PaprikaLog.smc.info(
            "SMC 탐지 완료: backend=\(caps.backend.rawValue, privacy: .public) adapter=\(caps.adapterKey.rawValue, privacy: .public) keys=\(caps.usableKeys.count, privacy: .public)"
        )
    }

    // MARK: 충전 허용/차단 (직접 제어 백엔드)

    /// 현재 하드웨어가 충전을 허용하는 상태인지 읽는다.
    public func isChargingAllowed() throws -> Bool {
        switch capabilities.backend {
        case .classicLegacy:
            let value = try smc.read(SMCKeys.chargeInhibitA)
            return value.uint8 == SMCChargeValues.classicAllow
        case .tahoeLegacy:
            let value = try smc.read(SMCKeys.chargeInhibitTahoe)
            return value.bytes.prefix(4).elementsEqual(SMCChargeValues.tahoeAllow)
        case .firmware:
            // 펌웨어 위임 모드에서는 "제한이 걸려 있지 않은가"로 해석한다.
            return try !firmwareLimit().active
        case .unsupported:
            return true
        }
    }

    /// 충전 허용 여부를 설정한다. 이미 원하는 상태면 쓰지 않는다.
    /// - Returns: 실제로 SMC 에 썼으면 true.
    @discardableResult
    public func setCharging(allowed: Bool) throws -> Bool {
        switch capabilities.backend {
        case .classicLegacy:
            let target: UInt8 = allowed ? SMCChargeValues.classicAllow : SMCChargeValues.classicInhibit
            let current = try? smc.read(SMCKeys.chargeInhibitA).uint8
            if current == target {
                // B 키도 같은지 확인한다(둘이 어긋나면 하드웨어가 헷갈린다).
                if (try? smc.read(SMCKeys.chargeInhibitB).uint8) == target { return false }
            }
            try smc.write(SMCKeys.chargeInhibitA, byte: target)
            try smc.write(SMCKeys.chargeInhibitB, byte: target)
            return true

        case .tahoeLegacy:
            let target = allowed ? SMCChargeValues.tahoeAllow : SMCChargeValues.tahoeInhibit
            if let current = try? smc.read(SMCKeys.chargeInhibitTahoe).bytes,
               current.prefix(4).elementsEqual(target) {
                return false
            }
            try smc.write(SMCKeys.chargeInhibitTahoe, bytes: target)
            return true

        case .firmware:
            throw SMCError.keyUnavailable(L.s("직접 충전 제어 키", "direct charge control keys"))

        case .unsupported:
            throw SMCError.keyUnavailable(L.s("충전 제어 키", "charge control keys"))
        }
    }

    // MARK: 어댑터 제어 (꽂은 채로 방전)

    public func isAdapterEnabled() throws -> Bool {
        guard capabilities.adapterKey != .none else { return true }
        let value = try smc.read(capabilities.adapterKey.rawValue)
        return value.uint8 == SMCChargeValues.adapterEnable
    }

    @discardableResult
    public func setAdapter(enabled: Bool) throws -> Bool {
        let key = capabilities.adapterKey
        guard key != .none else {
            if enabled { return false }  // 어차피 기본 상태가 "사용"이므로 무해
            throw SMCError.keyUnavailable(L.s("어댑터 제어 키", "adapter control key"))
        }
        let target: UInt8 = enabled ? SMCChargeValues.adapterEnable : key.disableValue
        if let current = try? smc.read(key.rawValue).uint8, current == target {
            return false
        }
        try smc.write(key.rawValue, byte: target)
        return true
    }

    // MARK: 펌웨어 제한

    public func firmwareLimit() throws -> FirmwareChargeLimit {
        guard capabilities.hasFirmwareLimitKeys else {
            throw SMCError.keyUnavailable(SMCKeys.firmwareLimitActivation)
        }
        let activation = try smc.read(SMCKeys.firmwareLimitActivation)
        let upper = try readFirmwarePercent(SMCKeys.firmwareLimitUpper)
        let lower = try readFirmwarePercent(SMCKeys.firmwareLimitLower)
        return FirmwareChargeLimit(
            active: activation.uint8 == SMCChargeValues.firmwareLimitOn,
            lower: lower,
            upper: upper
        )
    }

    /// bfD0/bfE0 는 ui32 로 선언돼 있지만 퍼센트를 리틀엔디언으로 담는다.
    /// (50% → `32 00 00 00`)
    private func readFirmwarePercent(_ key: String) throws -> Int {
        let value = try smc.read(key)
        guard let raw = value.uint32 else {
            throw SMCError.decodeFailed(key: key, type: value.type)
        }
        return Int(min(raw, 100))
    }

    private func writeFirmwarePercent(_ key: String, percent: Int) throws {
        let clamped = UInt8(max(0, min(100, percent)))
        let info = try smc.keyInfo(key)
        var payload = [UInt8](repeating: 0, count: max(1, info.dataSize))
        payload[0] = clamped
        try smc.write(key, bytes: payload)
    }

    /// 펌웨어 제한을 원하는 범위로 맞춘다. 이미 맞으면 아무것도 쓰지 않는다.
    ///
    /// 쓰기 순서(비활성 → 상한 → 하한 → 활성)는 펌웨어가 요구하는 순서다.
    /// - Returns: 실제로 바꿨으면 true.
    @discardableResult
    public func setFirmwareLimit(lower: Int, upper: Int) throws -> Bool {
        guard capabilities.hasFirmwareLimitKeys else {
            throw SMCError.keyUnavailable(SMCKeys.firmwareLimitActivation)
        }
        let safeUpper = max(20, min(100, upper))
        let safeLower = max(0, min(safeUpper - 1, lower))

        let current = try firmwareLimit()
        if current.active, current.upper == safeUpper, current.lower == safeLower {
            return false
        }

        try smc.write(SMCKeys.firmwareLimitActivation, byte: SMCChargeValues.firmwareLimitOff)
        try writeFirmwarePercent(SMCKeys.firmwareLimitUpper, percent: safeUpper)
        try writeFirmwarePercent(SMCKeys.firmwareLimitLower, percent: safeLower)
        try smc.write(SMCKeys.firmwareLimitActivation, byte: SMCChargeValues.firmwareLimitOn)
        return true
    }

    @discardableResult
    public func disableFirmwareLimit() throws -> Bool {
        guard capabilities.hasFirmwareLimitKeys else { return false }
        let activation = try smc.read(SMCKeys.firmwareLimitActivation)
        if activation.uint8 == SMCChargeValues.firmwareLimitOff { return false }
        try smc.write(SMCKeys.firmwareLimitActivation, byte: SMCChargeValues.firmwareLimitOff)
        return true
    }

    // MARK: MagSafe LED

    public func magSafeLED() throws -> MagSafeLEDState {
        guard capabilities.hasMagSafeLED else {
            throw SMCError.keyUnavailable(SMCKeys.magSafeLED)
        }
        let value = try smc.read(SMCKeys.magSafeLED)
        guard let raw = value.uint8 else {
            throw SMCError.decodeFailed(key: SMCKeys.magSafeLED, type: value.type)
        }
        // 문서화되지 않은 값(예: 0x02)은 초록으로 취급한다.
        return MagSafeLEDState(rawValue: raw) ?? (raw == 0x02 ? .green : .system)
    }

    @discardableResult
    public func setMagSafeLED(_ state: MagSafeLEDState) throws -> Bool {
        guard capabilities.hasMagSafeLED else { return false }
        if let current = try? smc.read(SMCKeys.magSafeLED).uint8, current == state.rawValue {
            return false
        }
        try smc.write(SMCKeys.magSafeLED, byte: state.rawValue)
        return true
    }

    // MARK: 전력 텔레메트리

    public func readTelemetry() -> PowerTelemetry {
        var telemetry = PowerTelemetry()
        telemetry.adapterWatts = numeric(SMCKeys.dcInPower)
        telemetry.adapterVolts = numeric(SMCKeys.dcInVoltage)
        telemetry.adapterAmps = numeric(SMCKeys.dcInCurrent)
        telemetry.batteryWatts = numeric(SMCKeys.batteryPower)
        telemetry.batteryVolts = numeric(SMCKeys.batteryVoltage)
        telemetry.batteryAmps = numeric(SMCKeys.batteryCurrent)
        telemetry.smcChargePercent = numeric(SMCKeys.batteryCharge).map { Int($0) }
        telemetry.temperature = [
            SMCKeys.batteryTemperature0,
            SMCKeys.batteryTemperature1,
            SMCKeys.batteryTemperature2,
        ].compactMap { numeric($0) }.filter { $0 > 0 && $0 < 120 }.max()
        if let acw = try? smc.read(SMCKeys.acPower).int8 {
            telemetry.acConnected = acw > 0
        }
        return telemetry
    }

    private func numeric(_ key: String) -> Double? {
        guard capabilities.usableKeys[key] != nil else { return nil }
        return (try? smc.read(key))?.numericValue
    }

    // MARK: 원상복구

    /// 하드웨어를 "우리가 손대기 전" 상태로 되돌린다.
    ///
    /// 데몬 종료, 언인스톨, 사용자 요청 시 반드시 호출된다. 개별 실패는 무시하고
    /// 최대한 많이 되돌리는 게 목적이다(충전이 막힌 채로 남는 게 최악의 결과).
    public func restoreDefaults() -> [String] {
        var failures: [String] = []

        if capabilities.backend.allowsDirectControl {
            do { _ = try setCharging(allowed: true) } catch { failures.append("charging: \(error)") }
        }
        if capabilities.adapterKey != .none {
            do { _ = try setAdapter(enabled: true) } catch { failures.append("adapter: \(error)") }
        }
        if capabilities.hasFirmwareLimitKeys {
            do { _ = try disableFirmwareLimit() } catch { failures.append("firmwareLimit: \(error)") }
        }
        if capabilities.hasMagSafeLED {
            do { _ = try setMagSafeLED(.system) } catch { failures.append("magSafeLED: \(error)") }
        }

        if failures.isEmpty {
            PaprikaLog.smc.notice("하드웨어를 기본 상태로 복구했습니다.")
        } else {
            PaprikaLog.smc.error("복구 중 일부 실패: \(failures.joined(separator: "; "), privacy: .public)")
        }
        return failures
    }

    // MARK: 진단 덤프

    public func dump(includeAllKeys: Bool) -> SMCDump {
        var entries: [SMCDumpEntry] = []
        let keys: [String]
        if includeAllKeys {
            let all = smc.allKeyNames(limit: 4096)
            keys = all.isEmpty ? SMCKeys.diagnosticKeys : all
        } else {
            keys = SMCKeys.diagnosticKeys
        }

        for key in keys {
            let info = try? smc.keyInfo(key)
            var entry = SMCDumpEntry(
                key: key,
                dataType: info?.dataType ?? "?",
                dataSize: info?.dataSize ?? 0,
                hex: nil,
                value: nil,
                error: nil
            )
            if let info, info.isUsable {
                do {
                    let value = try smc.read(key)
                    entry.hex = value.hexString
                    entry.value = value.numericValue
                } catch {
                    entry.error = String(describing: error)
                }
            } else if info == nil {
                entry.error = L.s("키 없음", "key not present")
            } else {
                entry.error = L.s("크기 0 (placeholder)", "size 0 (placeholder)")
            }
            entries.append(entry)
        }

        return SMCDump(
            generatedAt: Date(),
            system: SystemInfo.current(),
            capabilities: capabilities,
            entries: entries
        )
    }
}

// MARK: - 진단 모델

public struct SMCDumpEntry: Codable, Equatable, Sendable {
    public var key: String
    public var dataType: String
    public var dataSize: Int
    public var hex: String?
    public var value: Double?
    public var error: String?
}

public struct SMCDump: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var system: SystemInfo
    public var capabilities: HardwareCapabilities
    public var entries: [SMCDumpEntry]

    public func plainText() -> String {
        var lines: [String] = []
        lines.append("Paprika SMC dump — \(ISO8601DateFormatter().string(from: generatedAt))")
        lines.append("model=\(system.modelIdentifier) chip=\(system.chipName) os=\(system.osVersion)")
        lines.append("backend=\(capabilities.backend.rawValue) adapterKey=\(capabilities.adapterKey.rawValue)")
        lines.append("firmwareLimitKeys=\(capabilities.hasFirmwareLimitKeys) directKeys=\(capabilities.hasDirectKeys) magSafeLED=\(capabilities.hasMagSafeLED)")
        lines.append("")
        lines.append("KEY    TYPE  SZ   HEX                        VALUE")
        for entry in entries {
            let value: String
            if let error = entry.error {
                value = "! \(error)"
            } else if let number = entry.value {
                value = String(format: "%.4g", number)
            } else {
                value = "-"
            }
            lines.append(
                entry.key.padding(toLength: 6, withPad: " ", startingAt: 0)
                    + " " + entry.dataType.padding(toLength: 5, withPad: " ", startingAt: 0)
                    + " " + String(entry.dataSize).padding(toLength: 4, withPad: " ", startingAt: 0)
                    + " " + (entry.hex ?? "-").padding(toLength: 26, withPad: " ", startingAt: 0)
                    + " " + value
            )
        }
        return lines.joined(separator: "\n")
    }
}
