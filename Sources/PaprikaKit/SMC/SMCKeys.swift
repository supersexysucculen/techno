//
//  SMCKeys.swift
//  PaprikaKit
//
//  Apple Silicon 맥북에서 충전 제어에 쓰이는 SMC 키 목록.
//
//  이 키들의 의미는 공개된 오픈소스 프로젝트들의 문서/소스에서 확인한 하드웨어
//  사실(fact)이다. 자세한 출처는 README 의 "참고 자료" 절에 적어두었다.
//

import Foundation

public enum SMCKeys {
    // MARK: 충전 제어 — 구형 경로 (M1 ~ M3, macOS 13~15 대)

    /// 충전 억제 키 A. `0x00` 허용 / `0x02` 차단.
    public static let chargeInhibitA = "CH0B"
    /// 충전 억제 키 B. CH0B 와 함께 같은 값을 써야 한다.
    public static let chargeInhibitB = "CH0C"

    /// Tahoe(macOS 26) 계열 펌웨어에서 CH0B/CH0C 를 대체하는 키.
    /// 4바이트. `00 00 00 00` 허용 / `01 00 00 00` 차단.
    public static let chargeInhibitTahoe = "CHTE"

    // MARK: 충전 제어 — 펌웨어 위임 경로 (최신 펌웨어)

    /// 펌웨어 충전 제한 활성화. `0x00` 비활성 / `0x02` 활성.
    public static let firmwareLimitActivation = "bfF0"
    /// 펌웨어 충전 상한(%). ui32 지만 리틀엔디언으로 저장된다.
    public static let firmwareLimitUpper = "bfD0"
    /// 펌웨어 충전 하한(%). 상한까지 올라간 뒤 이 값 밑으로 떨어지면 다시 충전한다.
    public static let firmwareLimitLower = "bfE0"

    // MARK: 어댑터 제어 (플러그를 꽂은 채로 방전시키기)

    /// `0x00` 어댑터 사용 / `0x01` 어댑터 차단.
    public static let adapterInhibitA = "CH0I"
    /// A 가 없을 때의 대체 키. 값 규칙은 동일.
    public static let adapterInhibitB = "CH0J"
    /// Tahoe 계열. `0x00` 사용 / `0x08` 차단. (차단 값이 다르다!)
    public static let adapterInhibitTahoe = "CHIE"

    // MARK: 상태 읽기

    /// AC 연결 여부. si8 이 0 보다 크면 연결됨.
    public static let acPower = "AC-W"
    /// 배터리 충전량(%). 1바이트.
    public static let batteryCharge = "BUIC"

    // MARK: MagSafe LED

    /// MagSafe LED 색. MagSafeLEDState 참고.
    public static let magSafeLED = "ACLC"

    // MARK: 전력 텔레메트리

    /// DC 입력 전류(A).
    public static let dcInCurrent = "ID0R"
    /// DC 입력 전압(V).
    public static let dcInVoltage = "VD0R"
    /// DC 입력 전력(W).
    public static let dcInPower = "PDTR"
    /// 배터리 전류(A). 음수면 방전.
    public static let batteryCurrent = "B0AC"
    /// 배터리 전압(V).
    public static let batteryVoltage = "B0AV"
    /// 배터리 전력(W).
    public static let batteryPower = "PPBR"

    // MARK: 온도

    public static let batteryTemperature0 = "TB0T"
    public static let batteryTemperature1 = "TB1T"
    public static let batteryTemperature2 = "TB2T"

    /// 키별로 우리가 기대하는 데이터 크기(바이트).
    ///
    /// 왜 필요한가: 기능 탐지가 `dataSize > 0` 만 본다면, 예컨대 `CHTE` 를 1바이트로
    /// 보고하는 펌웨어에서 "지원됨"으로 판단한 뒤 4바이트를 쓰려다 매번 실패한다.
    /// 실패해도 위험하지는 않지만(충전이 막히지 않는다) 사용자는 원인을 알 수 없다.
    /// 그래서 탐지 단계에서 폭까지 확인하고, 다르면 진단에 그 이유를 남긴다.
    ///
    /// 여기에 없는 키는 폭을 검사하지 않는다(읽기 전용 텔레메트리 등).
    public static let expectedWidths: [String: Int] = [
        chargeInhibitA: 1,
        chargeInhibitB: 1,
        chargeInhibitTahoe: 4,
        firmwareLimitActivation: 1,
        firmwareLimitUpper: 4,
        firmwareLimitLower: 4,
        adapterInhibitA: 1,
        adapterInhibitB: 1,
        adapterInhibitTahoe: 1,
        magSafeLED: 1,
    ]

    /// 기능 탐지(capability probe)에 쓰는 키 전체.
    public static let probeKeys: [String] = [
        chargeInhibitA, chargeInhibitB, chargeInhibitTahoe,
        firmwareLimitActivation, firmwareLimitUpper, firmwareLimitLower,
        adapterInhibitA, adapterInhibitB, adapterInhibitTahoe,
        acPower, batteryCharge, magSafeLED,
        dcInCurrent, dcInVoltage, dcInPower,
        batteryCurrent, batteryVoltage, batteryPower,
        batteryTemperature0, batteryTemperature1, batteryTemperature2,
    ]

    /// 진단 화면에서 보여줄 키(위 목록 + 몇 가지 참고값).
    public static let diagnosticKeys: [String] = probeKeys
}

// MARK: - 충전 억제 값

enum SMCChargeValues {
    /// CH0B / CH0C
    static let classicAllow: UInt8 = 0x00
    static let classicInhibit: UInt8 = 0x02

    /// CHTE (4바이트, 리틀엔디언)
    static let tahoeAllow: [UInt8] = [0x00, 0x00, 0x00, 0x00]
    static let tahoeInhibit: [UInt8] = [0x01, 0x00, 0x00, 0x00]

    /// CH0I / CH0J
    static let adapterEnable: UInt8 = 0x00
    static let adapterDisable: UInt8 = 0x01
    /// CHIE 는 차단 값이 다르다.
    static let adapterDisableTahoe: UInt8 = 0x08

    /// bfF0
    static let firmwareLimitOff: UInt8 = 0x00
    static let firmwareLimitOn: UInt8 = 0x02
}

// MARK: - MagSafe LED

public enum MagSafeLEDState: UInt8, Codable, CaseIterable, Sendable {
    /// 시스템 기본 동작에 맡김.
    case system = 0x00
    case off = 0x01
    case green = 0x03
    case orange = 0x04
    case errorOnce = 0x05
    case errorSlowBlink = 0x06
    case errorFastBlink = 0x07

    public var label: String {
        switch self {
        case .system: return L.s("시스템 기본", "System default")
        case .off: return L.s("꺼짐", "Off")
        case .green: return L.s("초록", "Green")
        case .orange: return L.s("주황", "Amber")
        case .errorOnce: return L.s("오류(1회)", "Error (once)")
        case .errorSlowBlink: return L.s("오류(느린 점멸)", "Error (slow blink)")
        case .errorFastBlink: return L.s("오류(빠른 점멸)", "Error (fast blink)")
        }
    }
}
