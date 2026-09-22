//
//  HelperProtocol.swift
//  PaprikaKit
//
//  앱 ↔ 데몬 XPC 인터페이스.
//
//  모든 payload 를 JSON Data 로 주고받는다. NSSecureCoding 클래스 화이트리스트를
//  관리하는 것보다 이 방식이 사고가 훨씬 적고, 버전이 어긋나도 디코딩 에러로
//  깔끔하게 실패한다.
//

import Foundation

@objc public protocol PaprikaHelperProtocol {

    /// 살아 있는지 + 버전 확인.
    func handshake(reply: @escaping (String, Int) -> Void)

    /// 현재 상태 한 장. reply 는 (snapshotJSON, errorMessage).
    func fetchSnapshot(reply: @escaping (Data?, String?) -> Void)

    /// 설정을 갱신하고 즉시 한 번 판단한다. reply 는 갱신된 snapshot.
    func updateConfig(_ configJSON: Data, reply: @escaping (Data?, String?) -> Void)

    /// 명령 실행. name 은 PaprikaCommand.rawValue.
    func performCommand(_ name: String, payload: Data?, reply: @escaping (Data?, String?) -> Void)

    /// SMC 진단 덤프.
    func smcDump(includeAllKeys: Bool, reply: @escaping (Data?, String?) -> Void)

    /// 하드웨어를 기본 상태로 되돌리고 데몬을 종료한다(언인스톨 직전에 사용).
    func restoreAndExit(reply: @escaping (String?) -> Void)
}

/// 데몬에 보낼 수 있는 명령.
public enum PaprikaCommand: String, Codable, Sendable {
    /// 이번 한 번만 100% 까지 충전
    case fullChargeOnce
    case cancelFullChargeOnce
    case startCalibration
    case cancelCalibration
    /// payload: PauseRequest
    case pause
    case resume
    /// 하드웨어를 기본 상태로 되돌린다(데몬은 계속 살아 있음)
    case resetHardware
    /// 하드웨어 기능 재탐지
    case redetectHardware
    /// 즉시 한 번 제어 루프를 돌린다
    case forceTick
    /// 이벤트 로그 비우기
    case clearEvents
}

public struct PauseRequest: Codable, Sendable {
    public var minutes: Int
    public init(minutes: Int) {
        self.minutes = minutes
    }
}

// MARK: - 상수 / 경로

public enum PaprikaIPC {
    /// launchd MachServices 에 등록하는 이름.
    public static let machServiceName = "com.paprika.helperd"

    /// 프로토콜 버전. 앱과 데몬이 어긋나면 UI 에서 경고한다.
    public static let protocolVersion = 1

    public static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: PaprikaHelperProtocol.self)
    }
}

public enum PaprikaPaths {
    public static let appBundleIdentifier = "com.paprika.Paprika"
    public static let helperIdentifier = "com.paprika.helperd"

    /// 데몬이 상태를 저장하는 곳 (root 소유).
    public static let daemonSupportDirectory = "/Library/Application Support/Paprika"
    public static var daemonStateFile: String { daemonSupportDirectory + "/state.json" }
    /// 이 파일이 있으면 XPC 피어 코드서명 검사를 건너뛴다(직접 빌드/디버깅용).
    public static var allowUnsignedPeersFile: String { daemonSupportDirectory + "/allow-unsigned-peers" }

    /// root 데몬 바이너리의 위치.
    ///
    /// `/usr/local/libexec` 이 아니라 `/Library/PrivilegedHelperTools` 를 쓴다.
    /// Homebrew 를 설치한 맥에서는 `/usr/local` 이 `root:admin` 775 라서 관리자
    /// 계정(= 보통의 사용자 계정)이 root 로 실행될 바이너리를 갈아치울 수 있다.
    /// 그러면 XPC 피어 서명을 검증하는 의미가 사라진다.
    public static let helperExecutable = "/Library/PrivilegedHelperTools/com.paprika.helperd"
    public static let helperLaunchDaemonPlist = "/Library/LaunchDaemons/com.paprika.helperd.plist"
    /// CLI 는 권한이 없는 단순 클라이언트이므로 표준 위치에 둔다.
    public static let cliExecutable = "/usr/local/bin/paprikactl"

    /// 앱이 히스토리/UI 설정을 저장하는 곳 (사용자 소유).
    public static var appSupportDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/Paprika"
    }
    public static var historyFile: String { appSupportDirectory + "/history.jsonl" }

    public static let loginItemLabel = "com.paprika.Paprika.login"
    public static var loginAgentPlist: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/LaunchAgents/\(loginItemLabel).plist"
    }
}

public enum PaprikaVersion {
    public static let current = "1.0.0"
}
