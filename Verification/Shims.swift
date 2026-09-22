//
//  Shims.swift
//  Verification
//
//  검증 하니스는 PaprikaKit 중 **플랫폼에 의존하지 않는 파일들만** 모아서 컴파일한다.
//  (Scripts/verify.sh 의 파일 목록 참고)
//
//  빠지는 것은 두 개뿐이다:
//    * PaprikaLog  — os.Logger 는 Darwin 전용
//    * SystemInfo  — sysctl 은 Darwin 전용
//
//  그 둘을 여기서 대체한다. 나머지는 전부 앱에 실제로 들어가는 그 코드다.
//  로그는 버리지 않고 모아둔다 — 탐지 결과가 로그에 제대로 남는지도 확인한다.
//

import Foundation

// MARK: - os.Logger 대체

/// `privacy:` 인자를 받아주기 위한 껍데기. os.OSLogPrivacy 와 같은 모양으로 맞춘다.
struct VerifyPrivacy {
    static let `public` = VerifyPrivacy()
    static let `private` = VerifyPrivacy()
    static let auto = VerifyPrivacy()
    static func sensitive() -> VerifyPrivacy { VerifyPrivacy() }
}

/// os.Logger 가 받는 OSLogMessage 를 흉내낸 타입.
/// `"... \(x, privacy: .public) ..."` 형태를 그대로 소화해야 한다.
struct VerifyLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: Interpolation) {
        text = stringInterpolation.output
    }

    struct Interpolation: StringInterpolationProtocol {
        var output = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            output.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        mutating func appendLiteral(_ literal: String) {
            output += literal
        }

        mutating func appendInterpolation<T>(_ value: T, privacy: VerifyPrivacy = .auto) {
            output += String(describing: value)
        }

        mutating func appendInterpolation<T>(
            _ value: T,
            align: Int = 0,
            privacy: VerifyPrivacy = .auto
        ) {
            output += String(describing: value)
        }
    }

    typealias StringInterpolation = Interpolation
}

/// 남은 로그를 모아두는 곳. 검증에서 "무엇이 기록됐는가"도 확인한다.
enum VerifyLogSink {
    struct Line {
        let category: String
        let level: String
        let message: String
    }

    static var lines: [Line] = []

    static func record(_ category: String, _ level: String, _ message: String) {
        lines.append(Line(category: category, level: level, message: message))
    }

    static func reset() {
        lines.removeAll()
    }

    static func contains(category: String, substring: String) -> Bool {
        lines.contains { $0.category == category && $0.message.contains(substring) }
    }

    static var errorCount: Int {
        lines.filter { $0.level == "error" }.count
    }
}

struct VerifyLogger {
    let category: String

    func debug(_ message: VerifyLogMessage) { VerifyLogSink.record(category, "debug", message.text) }
    func trace(_ message: VerifyLogMessage) { VerifyLogSink.record(category, "trace", message.text) }
    func info(_ message: VerifyLogMessage) { VerifyLogSink.record(category, "info", message.text) }
    func notice(_ message: VerifyLogMessage) { VerifyLogSink.record(category, "notice", message.text) }
    func warning(_ message: VerifyLogMessage) { VerifyLogSink.record(category, "warning", message.text) }
    func error(_ message: VerifyLogMessage) { VerifyLogSink.record(category, "error", message.text) }
    func critical(_ message: VerifyLogMessage) { VerifyLogSink.record(category, "critical", message.text) }
    func fault(_ message: VerifyLogMessage) { VerifyLogSink.record(category, "fault", message.text) }
}

enum PaprikaLog {
    static let subsystem = "com.paprika"
    static let smc = VerifyLogger(category: "smc")
    static let battery = VerifyLogger(category: "battery")
    static let policy = VerifyLogger(category: "policy")
    static let daemon = VerifyLogger(category: "daemon")
    static let ipc = VerifyLogger(category: "ipc")
    static let app = VerifyLogger(category: "app")
}

// MARK: - SystemInfo 대체

/// 실제 구현은 sysctl 을 읽는다. 검증에서는 고정값을 쓰고, 필요하면 바꿔 끼운다.
public struct SystemInfo: Codable, Equatable, Sendable {
    public var modelIdentifier: String
    public var chipName: String
    public var isAppleSilicon: Bool
    public var osVersion: String

    public init(modelIdentifier: String, chipName: String, isAppleSilicon: Bool, osVersion: String) {
        self.modelIdentifier = modelIdentifier
        self.chipName = chipName
        self.isAppleSilicon = isAppleSilicon
        self.osVersion = osVersion
    }

    /// 검증 중에 바꿔 끼울 수 있는 현재 기기 정보.
    public static var stub = SystemInfo(
        modelIdentifier: "Mac15,3",
        chipName: "Apple M3 Pro",
        isAppleSilicon: true,
        osVersion: "Version 26.0 (Build 26A000)"
    )

    public static func current() -> SystemInfo { stub }

    public var majorOSVersion: Int { 26 }
}
