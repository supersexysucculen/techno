//
//  BatteryReader.swift
//  PaprikaKit
//
//  AppleSmartBattery IORegistry 노드에서 배터리 상태를 읽는다.
//  root 권한이 필요 없으므로 앱에서도 쓸 수 있다(데몬이 죽었을 때 UI 폴백).
//
//  해석 로직은 BatteryPropertyParser 에 있다 — 이 파일은 IOKit 에서 딕셔너리를
//  꺼내오는 일만 한다.
//

import Foundation
import IOKit

public final class BatteryReader {
    public init() {}

    /// - Returns: 배터리가 없거나 읽기에 실패하면 nil.
    public func read() -> BatteryInfo? {
        guard let properties = Self.copyProperties() else { return nil }
        return BatteryPropertyParser.parse(properties)
    }

    /// AppleSmartBattery 의 IORegistry 속성을 그대로 꺼내온다.
    /// 진단 화면에서 원본을 보여줄 때도 쓴다.
    public static func copyProperties() -> [String: Any]? {
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
        return properties
    }

    /// 예전 호출부 호환용.
    public static func parse(_ properties: [String: Any]) -> BatteryInfo {
        BatteryPropertyParser.parse(properties)
    }
}
