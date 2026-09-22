//
//  SystemInfo.swift
//  PaprikaKit
//

import Foundation

public struct SystemInfo: Codable, Equatable, Sendable {
    public var modelIdentifier: String
    public var chipName: String
    public var isAppleSilicon: Bool
    public var osVersion: String

    public static func current() -> SystemInfo {
        SystemInfo(
            modelIdentifier: sysctlString("hw.model") ?? "unknown",
            chipName: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            isAppleSilicon: detectAppleSilicon(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    /// macOS 주 버전 (예: 26)
    public var majorOSVersion: Int {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion
    }

    private static func detectAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        // Rosetta 로 실행 중일 수도 있으니 sysctl 도 확인한다.
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
            return value == 1
        }
        var translated: Int32 = 0
        var tSize = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &tSize, nil, 0) == 0 {
            return translated == 1
        }
        return false
        #endif
    }

    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // String(cString: [CChar]) 은 deprecated 이므로 직접 NUL 까지 잘라 디코딩한다.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
