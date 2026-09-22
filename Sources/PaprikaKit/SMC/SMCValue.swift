//
//  SMCValue.swift
//  PaprikaKit
//
//  SMC 키의 메타데이터와 값, 그리고 오류 타입.
//
//  Apple Silicon 의 SMC 는 숫자를 리틀엔디언으로 저장한다(sp78 은 예외적으로
//  빅엔디언). 이 파일도 IOKit 에 의존하지 않으므로 검증 하니스에서 그대로 돌린다.
//

import Foundation

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
