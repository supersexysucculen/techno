//
//  SMCParamStruct.swift
//  PaprikaKit
//
//  AppleSMC 커널 드라이버와 주고받는 구조체의 ABI 정의.
//
//  IOKit 에 의존하지 않는 순수 Foundation 코드다. 일부러 이렇게 떼어놓았다 —
//  Verification/ 의 검증 하니스가 맥이 아닌 곳에서도 이 레이아웃을 실제로
//  측정해볼 수 있어야 하기 때문이다.
//
//  레이아웃 주의사항
//  ----------------
//  커널은 정확히 80바이트인 구조체를 기대한다. C 에서의 오프셋:
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
//  아래 SMCKeyInfoData 의 _pad0..2 가 그 역할이고, 이게 없으면 keyInfo 가 9바이트가
//  되어 result 가 40 → 37 로 밀리면서 그 뒤의 모든 필드가 깨진다.
//  (SMCParamStruct.byteLayoutIsValid 로 런타임에서도 검증한다)
//

import Foundation

// MARK: - 커널 ABI

/// AppleSMC 의 IOConnectCallStructMethod selector.
let kKernelIndexSMC: UInt32 = 2

/// `SMCParamStruct.data8` 에 넣는 하위 명령 코드.
enum SMCSelector: UInt8 {
    case readKey = 5
    case writeKey = 6
    case keyFromIndex = 8
    case keyInfo = 9
}

/// SMC 가 돌려주는 result 코드 중 우리가 신경 쓰는 값들.
enum SMCResult {
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
