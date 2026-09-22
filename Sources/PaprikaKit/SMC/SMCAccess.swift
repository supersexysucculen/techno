//
//  SMCAccess.swift
//  PaprikaKit
//
//  SMC 접근을 프로토콜로 한 겹 감싼다.
//
//  왜 필요한가
//  ----------
//  ChargeHardware 가 SMCConnection(= IOKit) 에 직접 의존하면, 충전을 켜고 끄는
//  코드를 맥 밖에서 단 한 줄도 실행해볼 수 없다. 그런데 그 코드는 틀리면
//  "충전이 영구히 막힌다"는 결과가 나오는, 이 앱에서 가장 위험한 부분이다.
//
//  그래서 이음새를 하나 둔다. 실제 앱은 SMCConnection 을 쓰고, Verification/ 의
//  검증 하니스는 메모리상의 가짜 SMC 를 끼워서 **같은 ChargeHardware 코드**를
//  수천 번 돌린다.
//

import Foundation

/// SMC 읽기/쓰기에 필요한 최소한의 동작.
public protocol SMCAccess: AnyObject {
    /// 키의 크기/타입을 조회한다.
    func keyInfo(_ key: String) throws -> SMCKeyInfo
    /// 값을 읽는다.
    func read(_ key: String) throws -> SMCValue
    /// 값을 쓴다. 바이트 수가 키의 크기와 정확히 같아야 한다.
    func write(_ key: String, bytes payload: [UInt8]) throws
    /// 등록된 키 이름을 열거한다(진단용, 느림).
    func allKeyNames(limit: Int) -> [String]
}

public extension SMCAccess {
    /// 키가 실제로 쓸 수 있는 상태인지.
    ///
    /// macOS 26(Tahoe) 이후 일부 펌웨어는 `CH0B` 같은 키를 **dataSize 0** 으로만
    /// 남겨둔다. 존재 여부만 보면 "지원됨"으로 오판하므로 크기까지 확인해야 한다.
    func isKeyUsable(_ key: String) -> Bool {
        (try? keyInfo(key))?.isUsable ?? false
    }

    /// 1바이트 키 쓰기 헬퍼.
    func write(_ key: String, byte: UInt8) throws {
        try write(key, bytes: [byte])
    }
}
