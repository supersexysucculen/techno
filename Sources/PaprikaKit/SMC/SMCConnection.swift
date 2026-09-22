//
//  SMCConnection.swift
//  PaprikaKit
//
//  AppleSMC(시스템 관리 컨트롤러) 저수준 접근 계층.
//
//  읽기는 누구나 가능하지만 "쓰기"는 root 권한이 필요하다. 그래서 실제 쓰기는
//  paprikad(LaunchDaemon)에서만 일어난다.
//
//  구조체 레이아웃 주의사항
//  ------------------------
//  AppleSMC 커널 드라이버는 정확히 80바이트인 구조체를 주고받는다.
//  C 에서의 오프셋은 다음과 같다:
//
//      key        0 ..<  4
//      vers       4 ..< 10   (+2 패딩)
//      pLimitData 12 ..< 28
//      keyInfo    28 ..< 40  (C 에서 sizeof == 12, 뒤에 3바이트 패딩)
//      result     40
//      status     41
//      data8      42         (+1 패딩)
//      data32     44 ..< 48
//      bytes      48 ..< 80
//      총 80바이트
//
//  Swift 의 구조체 레이아웃 알고리즘은 "중첩 구조체의 size(stride 아님)"를 이어서
//  쌓기 때문에, C 의 꼬리 패딩을 명시적으로 넣어주지 않으면 offset 이 밀린다.
//  아래 SMCKeyInfoData 에 _pad0..2 를 직접 넣어 sizeof == 12 를 맞췄다.
//  (SMCParamStruct.byteLayoutIsValid 로 런타임에서도 검증한다)
//

import Foundation
import IOKit

// MARK: - 커널 ABI

/// AppleSMC 의 IOConnectCallStructMethod selector.
private let kKernelIndexSMC: UInt32 = 2

/// `SMCParamStruct.data8` 에 넣는 하위 명령 코드.
private enum SMCSelector: UInt8 {
    case readKey = 5
    case writeKey = 6
    case keyFromIndex = 8
    case keyInfo = 9
}

/// SMC 가 돌려주는 result 코드 중 우리가 신경 쓰는 값들.
private enum SMCResult {
    static let success: UInt8 = 0
    static let keyNotFound: UInt8 = 132  // 0x84
}

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // C 의 꼬리 패딩을 명시적으로 재현 (sizeof == 12)
    private var _pad0: UInt8 = 0
    private var _pad1: UInt8 = 0
    private var _pad2: UInt8 = 0
}

/// SMC 는 한 번에 최대 32바이트를 주고받는다.
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    /// 커널이 기대하는 80바이트 레이아웃인지 확인한다.
    /// 툴체인이 바뀌어 레이아웃이 어긋나면 SMC 에 쓰레기값을 쓰는 대신 바로 막는다.
    static var byteLayoutIsValid: Bool {
        MemoryLayout<SMCParamStruct>.size == 80
            && MemoryLayout<SMCParamStruct>.stride == 80
            && MemoryLayout<SMCKeyInfoData>.size == 12
            && MemoryLayout<SMCVersion>.size == 6
            && MemoryLayout<SMCPLimitData>.size == 16
    }
}

/// SMC 최대 payload 크기.
public let smcMaxDataSize = 32

// MARK: - 공개 타입

public enum SMCError: Error, CustomStringConvertible, Equatable {
    case badStructLayout(Int)
    case serviceNotFound
    case openFailed(Int32)
    case notConnected
    case ioKitCallFailed(key: String, code: Int32)
    case keyNotFound(String)
    case keyUnavailable(String)
    case smcFailure(key: String, result: UInt8)
    case sizeMismatch(key: String, expected: Int, got: Int)
    case sizeTooLarge(key: String, size: Int)
    case decodeFailed(key: String, type: String)

    public var description: String {
        switch self {
        case .badStructLayout(let size):
            return "SMCParamStruct 레이아웃이 80바이트가 아님 (\(size)바이트). 이 빌드로는 SMC 를 건드리지 않습니다."
        case .serviceNotFound:
            return "AppleSMC IOService 를 찾을 수 없습니다."
        case .openFailed(let code):
            return "AppleSMC 열기 실패 (IOReturn 0x\(String(code, radix: 16)))."
        case .notConnected:
            return "SMC 연결이 닫혀 있습니다."
        case .ioKitCallFailed(let key, let code):
            return "\(key): IOKit 호출 실패 (IOReturn 0x\(String(code, radix: 16)))."
        case .keyNotFound(let key):
            return "\(key): 이 기기의 SMC 에 없는 키입니다."
        case .keyUnavailable(let key):
            return "\(key): 키는 있지만 데이터 크기가 0 입니다(펌웨어 placeholder)."
        case .smcFailure(let key, let result):
            return "\(key): SMC 가 result=\(result) 를 반환했습니다."
        case .sizeMismatch(let key, let expected, let got):
            return "\(key): \(expected)바이트를 기대했는데 \(got)바이트를 받았습니다."
        case .sizeTooLarge(let key, let size):
            return "\(key): SMC 가 \(size)바이트라고 보고했습니다(최대 \(smcMaxDataSize)). 이 키는 다루지 않습니다."
        case .decodeFailed(let key, let type):
            return "\(key): '\(type)' 타입 값을 해석할 수 없습니다."
        }
    }
}

/// SMC 키의 메타데이터.
public struct SMCKeyInfo: Codable, Equatable, Sendable {
    public let key: String
    public let dataSize: Int
    public let dataType: String
    public let attributes: UInt8

    /// 펌웨어가 껍데기만 노출하는 키(dataSize == 0)는 읽기/쓰기가 불가능하므로
    /// "지원됨"으로 취급해서는 안 된다.
    public var isUsable: Bool { dataSize > 0 }

    public init(key: String, dataSize: Int, dataType: String, attributes: UInt8) {
        self.key = key
        self.dataSize = dataSize
        self.dataType = dataType
        self.attributes = attributes
    }
}

/// SMC 에서 읽은 원시 값.
///
/// Apple Silicon 의 SMC 는 숫자 타입을 **리틀엔디언**으로 저장한다.
public struct SMCValue: Codable, Equatable, Sendable {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    public init(key: String, type: String, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.bytes = bytes
    }

    public var uint8: UInt8? { bytes.first }

    public var uint16: UInt16? {
        guard bytes.count >= 2 else { return nil }
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    public var uint32: UInt32? {
        guard bytes.count >= 4 else { return nil }
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    public var int8: Int8? { bytes.first.map { Int8(bitPattern: $0) } }
    public var int16: Int16? { uint16.map { Int16(bitPattern: $0) } }
    public var int32: Int32? { uint32.map { Int32(bitPattern: $0) } }

    /// `flt ` — 리틀엔디언 IEEE-754 single.
    public var float: Float? { uint32.map { Float(bitPattern: $0) } }

    /// `sp78` — 부호 있는 7.8 고정소수점. 이 타입만은 빅엔디언으로 저장된다.
    public var sp78: Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        return Double(raw) / 256.0
    }

    public var flag: Bool? { bytes.first.map { $0 != 0 } }

    /// 타입 문자열을 보고 사람이 읽을 수 있는 숫자로 최대한 변환한다.
    public var numericValue: Double? {
        switch type {
        case "flt ": return float.map(Double.init)
        case "sp78": return sp78
        case "ui8 ", "flag", "hex_": return uint8.map(Double.init)
        case "si8 ": return int8.map(Double.init)
        case "ui16": return uint16.map(Double.init)
        case "si16": return int16.map(Double.init)
        case "ui32": return uint32.map(Double.init)
        case "si32": return int32.map(Double.init)
        default:
            if bytes.count == 1 { return Double(bytes[0]) }
            return nil
        }
    }

    public var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// MARK: - FourCharCode 변환

/// "CH0B" → 0x43483042
public func smcFourCharCode(_ key: String) -> UInt32 {
    var result: UInt32 = 0
    var count = 0
    for byte in key.utf8 {
        guard count < 4 else { break }
        result = (result << 8) | UInt32(byte)
        count += 1
    }
    // 4글자보다 짧으면 왼쪽 정렬로 채운다.
    while count < 4 {
        result = result << 8
        count += 1
    }
    return result
}

/// 0x666C7420 → "flt "
public func smcStringFromCode(_ code: UInt32) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    let scalars = bytes.map { byte -> Character in
        (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : " "
    }
    return String(scalars)
}

// MARK: - 연결

/// AppleSMC 로의 열린 연결 하나.
///
/// 스레드 안전하다(내부 락). 다만 SMC 자체가 느리기 때문에 호출을 남발하지 말자.
public final class SMCConnection {
    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private var keyInfoCache: [String: SMCKeyInfo] = [:]

    public init() throws {
        guard SMCParamStruct.byteLayoutIsValid else {
            throw SMCError.badStructLayout(MemoryLayout<SMCParamStruct>.size)
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { _ = IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let status = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard status == kIOReturnSuccess, conn != 0 else {
            throw SMCError.openFailed(status)
        }
        connection = conn
    }

    deinit {
        closeConnection()
    }

    public func closeConnection() {
        lock.lock()
        defer { lock.unlock() }
        if connection != 0 {
            _ = IOServiceClose(connection)
            connection = 0
        }
    }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != 0
    }

    // MARK: 원시 호출

    private func call(_ input: inout SMCParamStruct, key: String) throws -> SMCParamStruct {
        guard connection != 0 else { throw SMCError.notConnected }

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let status = IOConnectCallStructMethod(
            connection,
            kKernelIndexSMC,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )

        guard status == kIOReturnSuccess else {
            throw SMCError.ioKitCallFailed(key: key, code: status)
        }
        guard output.result != SMCResult.keyNotFound else {
            throw SMCError.keyNotFound(key)
        }
        guard output.result == SMCResult.success else {
            throw SMCError.smcFailure(key: key, result: output.result)
        }
        return output
    }

    // MARK: 키 정보

    /// 키의 크기/타입을 조회한다. 결과는 캐시된다(펌웨어가 바뀌지 않는 한 불변).
    public func keyInfo(_ key: String) throws -> SMCKeyInfo {
        lock.lock()
        defer { lock.unlock() }
        return try uncheckedKeyInfo(key)
    }

    private func uncheckedKeyInfo(_ key: String) throws -> SMCKeyInfo {
        if let cached = keyInfoCache[key] { return cached }

        var input = SMCParamStruct()
        input.key = smcFourCharCode(key)
        input.data8 = SMCSelector.keyInfo.rawValue

        let output = try call(&input, key: key)
        let reportedSize = Int(output.keyInfo.dataSize)

        // 32바이트를 넘는 크기는 잘라내지 말고 거부한다. 잘라낸 크기를 그대로
        // 커널에 다시 넘기면(쓰기 경로) 펌웨어에 틀린 길이를 알려주는 셈이 된다.
        guard reportedSize <= smcMaxDataSize else {
            throw SMCError.sizeTooLarge(key: key, size: reportedSize)
        }

        let info = SMCKeyInfo(
            key: key,
            dataSize: reportedSize,
            dataType: smcStringFromCode(output.keyInfo.dataType),
            attributes: output.keyInfo.dataAttributes
        )
        keyInfoCache[key] = info
        return info
    }

    /// 키가 실제로 쓸 수 있는 상태인지 확인한다.
    ///
    /// macOS 26(Tahoe) 이후 일부 펌웨어는 `CH0B` 같은 키를 **dataSize 0** 으로만
    /// 남겨둔다. 존재 여부만 보면 "지원됨"으로 오판하므로 크기까지 확인해야 한다.
    public func isKeyUsable(_ key: String) -> Bool {
        (try? keyInfo(key))?.isUsable ?? false
    }

    // MARK: 읽기

    public func read(_ key: String) throws -> SMCValue {
        lock.lock()
        defer { lock.unlock() }

        let info = try uncheckedKeyInfo(key)
        guard info.isUsable else { throw SMCError.keyUnavailable(key) }

        var input = SMCParamStruct()
        input.key = smcFourCharCode(key)
        input.keyInfo.dataSize = UInt32(info.dataSize)
        input.data8 = SMCSelector.readKey.rawValue

        let output = try call(&input, key: key)
        let raw = withUnsafeBytes(of: output.bytes) { buffer in
            Array(buffer.prefix(info.dataSize))
        }
        return SMCValue(key: key, type: info.dataType, bytes: raw)
    }

    // MARK: 쓰기 (root 필요)

    public func write(_ key: String, bytes payload: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }

        let info = try uncheckedKeyInfo(key)
        guard info.isUsable else { throw SMCError.keyUnavailable(key) }
        guard payload.count == info.dataSize else {
            throw SMCError.sizeMismatch(key: key, expected: info.dataSize, got: payload.count)
        }

        var input = SMCParamStruct()
        input.key = smcFourCharCode(key)
        input.keyInfo.dataSize = UInt32(info.dataSize)
        input.data8 = SMCSelector.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (index, byte) in payload.enumerated() where index < smcMaxDataSize {
                buffer[index] = byte
            }
        }

        _ = try call(&input, key: key)
    }

    /// 1바이트 키 쓰기 헬퍼.
    public func write(_ key: String, byte: UInt8) throws {
        try write(key, bytes: [byte])
    }

    // MARK: 전체 키 열거 (진단용)

    /// SMC 에 등록된 키 개수(`#KEY`).
    public func keyCount() throws -> Int {
        let value = try read("#KEY")
        // #KEY 는 ui32 이지만 빅엔디언으로 개수를 담는다.
        guard value.bytes.count >= 4 else { throw SMCError.decodeFailed(key: "#KEY", type: value.type) }
        let big = (UInt32(value.bytes[0]) << 24)
            | (UInt32(value.bytes[1]) << 16)
            | (UInt32(value.bytes[2]) << 8)
            | UInt32(value.bytes[3])
        let little = value.uint32 ?? 0
        // 둘 중 그럴듯한 값을 고른다(기기에 따라 1000~2000개 수준).
        return Int(big < 100_000 ? big : little)
    }

    /// 인덱스로 키 이름을 얻는다.
    public func key(at index: Int) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        var input = SMCParamStruct()
        input.data8 = SMCSelector.keyFromIndex.rawValue
        input.data32 = UInt32(index)

        let output = try call(&input, key: "#index\(index)")
        return smcStringFromCode(output.key)
    }

    /// 모든 키를 이름순으로 열거한다. 느리므로 진단용으로만 쓴다.
    public func allKeyNames(limit: Int = 4096) -> [String] {
        guard let count = try? keyCount() else { return [] }
        var names: [String] = []
        names.reserveCapacity(min(count, limit))
        for index in 0..<min(count, limit) {
            if let name = try? key(at: index) {
                names.append(name)
            }
        }
        return names
    }
}
