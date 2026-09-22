//
//  SMCConnection.swift
//  PaprikaKit
//
//  AppleSMC 로의 실제 IOKit 연결.
//
//  읽기는 누구나 가능하지만 "쓰기"는 root 권한이 필요하다. 그래서 실제 쓰기는
//  paprikad(LaunchDaemon)에서만 일어난다.
//
//  ABI 구조체는 SMCParamStruct.swift, 값 타입은 SMCValue.swift 에 있다.
//  이 파일만 IOKit 을 필요로 한다 — 그래서 ChargeHardware 는 이 클래스가 아니라
//  SMCAccess 프로토콜에 의존한다(SMCAccess.swift 참고).
//

import Foundation
import IOKit

// MARK: - 연결

/// AppleSMC 로의 열린 연결 하나.
///
/// 스레드 안전하다(내부 락). 다만 SMC 자체가 느리기 때문에 호출을 남발하지 말자.
public final class SMCConnection: SMCAccess {
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
