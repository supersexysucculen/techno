//
//  BatteryPropertyParser.swift
//  PaprikaKit
//
//  AppleSmartBattery IORegistry 속성 딕셔너리 → BatteryInfo.
//
//  IOKit 을 읽어오는 일(BatteryReader)과 해석하는 일(이 파일)을 나눠두었다.
//  해석 쪽은 순수 함수라서 맥이 아닌 곳에서도 그대로 검증할 수 있고, 실제로
//  Verification/ 하니스가 여러 기기 형태의 딕셔너리를 넣어보며 확인한다.
//
//  기기별 차이
//  ----------
//  * Apple Silicon: MaxCapacity == 100, CurrentCapacity == 퍼센트.
//    mAh 값은 AppleRawCurrentCapacity / NominalChargeCapacity 로 따로 온다.
//  * 인텔 시절: CurrentCapacity / MaxCapacity 가 둘 다 mAh.
//  * 일부 기기는 BatteryData 하위 딕셔너리에 StateOfCharge 를 준다(가장 정확).
//

import Foundation

public enum BatteryPropertyParser {

    /// 속성 딕셔너리를 BatteryInfo 로 해석한다.
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

        let currentCapacity = int(properties["CurrentCapacity"]) ?? 0
        let maxCapacity = int(properties["MaxCapacity"]) ?? 100
        if let stateOfCharge = int(batteryData["StateOfCharge"]), stateOfCharge >= 0, stateOfCharge <= 100 {
            info.percent = Double(stateOfCharge)
        } else if maxCapacity == 100 {
            info.percent = Double(currentCapacity)
        } else if maxCapacity > 0 {
            info.percent = Double(currentCapacity) / Double(maxCapacity) * 100
        }
        // 어떤 경로로 왔든 0...100 을 벗어나면 안 된다.
        info.percent = min(100, max(0, info.percent))

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
