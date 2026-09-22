//
//  FakeSMC.swift
//  Verification
//
//  메모리상의 가짜 SMC. SMCAccess 를 구현하므로 **실제 ChargeHardware 와
//  ChargeApplier 코드**를 그대로 구동할 수 있다.
//
//  기기 프로파일(M1 계열 / Tahoe 계열 / 펌웨어 위임 전용 / 미지원)을 미리 만들어 두고,
//  각 프로파일마다 모든 동작 조합을 돌려본다.
//

import Foundation

final class FakeSMC: SMCAccess {

    struct Entry {
        var type: String
        var bytes: [UInt8]
        /// 펌웨어가 껍데기만 노출하는 키 (dataSize == 0)
        var isPlaceholder: Bool = false
        /// 읽기는 되지만 쓰기는 거부하는 키 (엔타이틀먼트로 막힌 상황 재현)
        var readOnly: Bool = false
    }

    private(set) var storage: [String: Entry] = [:]

    // 관찰용 기록
    private(set) var writeLog: [(key: String, bytes: [UInt8])] = []
    private(set) var readCounts: [String: Int] = [:]
    private(set) var keyInfoCalls = 0

    /// 이 키들의 읽기는 IO 오류로 실패한다.
    var failingReads: Set<String> = []
    /// 이 키들의 쓰기는 IO 오류로 실패한다.
    var failingWrites: Set<String> = []

    init() {}

    // MARK: 구성

    func define(_ key: String, type: String, bytes: [UInt8], readOnly: Bool = false) {
        storage[key] = Entry(type: type, bytes: bytes, readOnly: readOnly)
    }

    /// dataSize == 0 인 껍데기 키. 존재하지만 읽기/쓰기가 불가능하다.
    func definePlaceholder(_ key: String) {
        storage[key] = Entry(type: "hex_", bytes: [], isPlaceholder: true)
    }

    /// 폭이 기대와 다른 키(예: CHTE 를 1바이트로 보고하는 펌웨어).
    func defineWrongWidth(_ key: String, bytes: Int) {
        storage[key] = Entry(type: "hex_", bytes: [UInt8](repeating: 0, count: bytes))
    }

    func remove(_ key: String) {
        storage.removeValue(forKey: key)
    }

    func bytes(of key: String) -> [UInt8]? {
        storage[key].flatMap { $0.isPlaceholder ? nil : $0.bytes }
    }

    func byte(of key: String) -> UInt8? {
        bytes(of: key)?.first
    }

    func resetObservations() {
        writeLog.removeAll()
        readCounts.removeAll()
        keyInfoCalls = 0
    }

    var writeCount: Int { writeLog.count }

    func writes(to key: String) -> [[UInt8]] {
        writeLog.filter { $0.key == key }.map(\.bytes)
    }

    // MARK: SMCAccess

    func keyInfo(_ key: String) throws -> SMCKeyInfo {
        keyInfoCalls += 1
        guard let entry = storage[key] else {
            throw SMCError.keyNotFound(key)
        }
        return SMCKeyInfo(
            key: key,
            dataSize: entry.isPlaceholder ? 0 : entry.bytes.count,
            dataType: entry.type,
            attributes: 0
        )
    }

    func read(_ key: String) throws -> SMCValue {
        readCounts[key, default: 0] += 1
        if failingReads.contains(key) {
            throw SMCError.ioKitCallFailed(key: key, code: -536_870_206)
        }
        guard let entry = storage[key] else {
            throw SMCError.keyNotFound(key)
        }
        guard !entry.isPlaceholder else {
            throw SMCError.keyUnavailable(key)
        }
        return SMCValue(key: key, type: entry.type, bytes: entry.bytes)
    }

    func write(_ key: String, bytes payload: [UInt8]) throws {
        if failingWrites.contains(key) {
            throw SMCError.ioKitCallFailed(key: key, code: -536_870_206)
        }
        guard var entry = storage[key] else {
            throw SMCError.keyNotFound(key)
        }
        guard !entry.isPlaceholder else {
            throw SMCError.keyUnavailable(key)
        }
        guard !entry.readOnly else {
            throw SMCError.smcFailure(key: key, result: 133)
        }
        // 실제 SMCConnection 과 같은 규칙: 크기가 정확히 맞아야 한다.
        guard payload.count == entry.bytes.count else {
            throw SMCError.sizeMismatch(key: key, expected: entry.bytes.count, got: payload.count)
        }
        entry.bytes = payload
        storage[key] = entry
        writeLog.append((key: key, bytes: payload))
    }

    func allKeyNames(limit: Int) -> [String] {
        Array(storage.keys.sorted().prefix(limit))
    }
}

// MARK: - 기기 프로파일

enum MachineProfile: String, CaseIterable {
    /// M1~M3 계열: CH0B/CH0C 직접 제어 + CH0I 어댑터 + MagSafe LED
    case classic
    /// macOS 26(Tahoe) 계열: CHTE 직접 제어 + CHIE 어댑터
    case tahoe
    /// 직접 제어 키가 껍데기만 남고 펌웨어 위임만 가능한 기기
    case firmwareOnly
    /// 직접 제어 + 펌웨어 키가 둘 다 있는 기기 (서로 싸우지 않아야 한다)
    case both
    /// 어댑터 제어 키가 없는 기기
    case noAdapter
    /// 충전 제어를 전혀 지원하지 않는 기기
    case unsupported

    var label: String {
        switch self {
        case .classic: return "classic (CH0B/CH0C + CH0I)"
        case .tahoe: return "tahoe (CHTE + CHIE)"
        case .firmwareOnly: return "firmwareOnly (bfF0/bfD0/bfE0)"
        case .both: return "both (CH0B/CH0C + bfF0)"
        case .noAdapter: return "noAdapter (CH0B/CH0C only)"
        case .unsupported: return "unsupported"
        }
    }

    var expectedBackend: ChargeControlBackend {
        switch self {
        case .classic, .noAdapter, .both: return .classicLegacy
        case .tahoe: return .tahoeLegacy
        case .firmwareOnly: return .firmware
        case .unsupported: return .unsupported
        }
    }

    var expectedAdapterKey: AdapterControlKey {
        switch self {
        case .classic, .both: return .ch0i
        case .tahoe: return .chie
        case .firmwareOnly: return .ch0i
        case .noAdapter, .unsupported: return .none
        }
    }

    func make() -> FakeSMC {
        let smc = FakeSMC()

        // 모든 기기에 공통으로 있는 읽기 전용 텔레메트리
        smc.define(SMCKeys.acPower, type: "si8 ", bytes: [1], readOnly: true)
        smc.define(SMCKeys.batteryCharge, type: "ui8 ", bytes: [80], readOnly: true)
        smc.define(SMCKeys.dcInPower, type: "flt ", bytes: [0x00, 0x00, 0x2A, 0x42], readOnly: true)  // 42.5W
        smc.define(SMCKeys.batteryPower, type: "flt ", bytes: [0x00, 0x00, 0x18, 0x41], readOnly: true)  // 9.5W
        smc.define(SMCKeys.batteryTemperature0, type: "flt ", bytes: [0x00, 0x00, 0xF4, 0x41], readOnly: true)  // 30.5°C

        switch self {
        case .classic, .noAdapter:
            smc.define(SMCKeys.chargeInhibitA, type: "hex_", bytes: [0x00])
            smc.define(SMCKeys.chargeInhibitB, type: "hex_", bytes: [0x00])
            smc.define(SMCKeys.magSafeLED, type: "ui8 ", bytes: [0x00])
            if self == .classic {
                smc.define(SMCKeys.adapterInhibitA, type: "hex_", bytes: [0x00])
            }

        case .tahoe:
            smc.define(SMCKeys.chargeInhibitTahoe, type: "hex_", bytes: [0x00, 0x00, 0x00, 0x00])
            smc.define(SMCKeys.adapterInhibitTahoe, type: "hex_", bytes: [0x00])
            // 구형 키는 껍데기만 남아 있다 — 이걸 "지원됨"으로 오판하면 안 된다.
            smc.definePlaceholder(SMCKeys.chargeInhibitA)
            smc.definePlaceholder(SMCKeys.chargeInhibitB)

        case .firmwareOnly:
            smc.define(SMCKeys.firmwareLimitActivation, type: "hex_", bytes: [0x00])
            smc.define(SMCKeys.firmwareLimitUpper, type: "ui32", bytes: [100, 0, 0, 0])
            smc.define(SMCKeys.firmwareLimitLower, type: "ui32", bytes: [0, 0, 0, 0])
            smc.define(SMCKeys.adapterInhibitA, type: "hex_", bytes: [0x00])
            smc.definePlaceholder(SMCKeys.chargeInhibitA)
            smc.definePlaceholder(SMCKeys.chargeInhibitB)
            smc.definePlaceholder(SMCKeys.chargeInhibitTahoe)

        case .both:
            smc.define(SMCKeys.chargeInhibitA, type: "hex_", bytes: [0x00])
            smc.define(SMCKeys.chargeInhibitB, type: "hex_", bytes: [0x00])
            smc.define(SMCKeys.adapterInhibitA, type: "hex_", bytes: [0x00])
            smc.define(SMCKeys.magSafeLED, type: "ui8 ", bytes: [0x00])
            // 펌웨어 제한이 이미 켜진 상태로 시작한다 (직접 제어가 이걸 꺼야 한다)
            smc.define(SMCKeys.firmwareLimitActivation, type: "hex_", bytes: [0x02])
            smc.define(SMCKeys.firmwareLimitUpper, type: "ui32", bytes: [80, 0, 0, 0])
            smc.define(SMCKeys.firmwareLimitLower, type: "ui32", bytes: [75, 0, 0, 0])

        case .unsupported:
            smc.definePlaceholder(SMCKeys.chargeInhibitA)
            smc.definePlaceholder(SMCKeys.chargeInhibitB)
            smc.definePlaceholder(SMCKeys.chargeInhibitTahoe)
            smc.definePlaceholder(SMCKeys.firmwareLimitActivation)
        }

        return smc
    }

    /// 하드웨어 래퍼까지 만들어서 돌려준다.
    func makeHardware() -> (FakeSMC, ChargeHardware) {
        let smc = make()
        let hardware = ChargeHardware(smc: smc)
        return (smc, hardware)
    }
}
