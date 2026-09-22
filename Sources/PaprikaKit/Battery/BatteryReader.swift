//
//  BatteryReader.swift
//  PaprikaKit
//
//  AppleSmartBattery IORegistry 노드에서 배터리 상태를 읽는다.
//  root 권한이 필요 없으므로 앱에서도 쓸 수 있다(데몬이 죽었을 때 UI 폴백).
//

import Foundation
import IOKit

public final class BatteryReader {
    public init() {}

    /// - Returns: 배터리가 없거나 읽기에 실패하면 nil.
    public func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            PaprikaLog.battery.error("AppleSmartBattery 서비스를 찾을 수 없습니다.")
            return nil
        }
        defer { _ = IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else {
            PaprikaLog.battery.error("AppleSmartBattery 속성을 읽지 못했습니다.")
            return nil
        }

        return Self.parse(properties)
    }

    /// 속성 딕셔너리 → BatteryInfo.
    /// 순수 함수라서 테스트/검증이 쉽다.
    public static func parse(_ properties: [String: Any]) -> BatteryInfo {
        var info = BatteryInfo()

        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]

        info.batteryInstalled = bool(properties["BatteryInstalled"]) ?? true
        info.isCharging = bool(properties["IsCharging"]) ?? false
        info.isPluggedIn = bool(properties["ExternalConnected"]) ?? false
        info.fullyCharged = bool(properties["FullyCharged"]) ?? false

        info.cycleCount = int(properties["CycleCount"]) ?? int(batteryData["CycleCount"]) ?? 0
        info.designCapacity = int(properties["DesignCapacity"]) ?? 0
        info.nominalCapacity = int(properties["NominalChargeCapacity"])
            ?? int(properties["AppleRawMaxCapacity"])
            ?? int(batteryData["NominalChargeCapacity"])
            ?? 0
        info.rawCurrentCapacity = int(properties["AppleRawCurrentCapacity"])
            ?? int(batteryData["AbsoluteCapacity"])
            ?? 0

        // 퍼센트: Apple Silicon 에서는 MaxCapacity == 100, CurrentCapacity == 퍼센트.
        let currentCapacity = int(properties["CurrentCapacity"]) ?? 0
        let maxCapacity = int(properties["MaxCapacity"]) ?? 100
        if let stateOfCharge = int(batteryData["StateOfCharge"]), stateOfCharge >= 0, stateOfCharge <= 100 {
            info.percent = Double(stateOfCharge)
        } else if maxCapacity == 100 {
            info.percent = Double(currentCapacity)
        } else if maxCapacity > 0 {
            info.percent = Double(currentCapacity) / Double(maxCapacity) * 100
        }

        // 소수점 퍼센트: mAh 원시값이 있으면 그걸로 계산한다.
        if info.rawCurrentCapacity > 0, info.nominalCapacity > 0 {
            info.precisePercent = min(100, Double(info.rawCurrentCapacity) / Double(info.nominalCapacity) * 100)
        } else {
            info.precisePercent = info.percent
        }

        if let millivolts = double(properties["Voltage"]) ?? double(batteryData["Voltage"]) {
            info.voltage = millivolts / 1000
        }
        if let milliamps = double(properties["Amperage"]) ?? double(batteryData["Amperage"]) {
            info.amperage = milliamps / 1000
        }
        if let centiDegrees = double(properties["Temperature"]) ?? double(batteryData["Temperature"]) {
            let celsius = centiDegrees / 100
            // 말도 안 되는 값은 버린다.
            if celsius > -20, celsius < 120 { info.temperature = celsius }
        }

        if let adapter = properties["AdapterDetails"] as? [String: Any] {
            info.adapterWatts = int(adapter["Watts"])
            info.adapterName = (adapter["Name"] as? String)
                ?? (adapter["Description"] as? String)
                ?? (adapter["Manufacturer"] as? String)
        }

        info.minutesToFull = sanitizeMinutes(int(properties["AvgTimeToFull"]) ?? int(properties["TimeRemaining"]))
        info.minutesToEmpty = sanitizeMinutes(int(properties["AvgTimeToEmpty"]))
        if info.minutesToEmpty == nil, !info.isPluggedIn {
            info.minutesToEmpty = sanitizeMinutes(int(properties["TimeRemaining"]))
        }

        info.serialNumber = (properties["BatterySerialNumber"] as? String)
            ?? (properties["Serial"] as? String)

        return info
    }

    /// 65535 / 0 은 "계산 중" 또는 무의미한 값이다.
    private static func sanitizeMinutes(_ value: Int?) -> Int? {
        guard let value, value > 0, value < 60 * 48 else { return nil }
        return value
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        return nil
    }
}
