//
//  PaprikaLog.swift
//  PaprikaKit
//
//  os.Logger 래퍼. 데몬 로그는 `log stream --predicate 'subsystem == "com.paprika"'`
//  로 볼 수 있고, paprikactl 로도 최근 이벤트를 꺼내볼 수 있다.
//

import Foundation
import os

public enum PaprikaLog {
    public static let subsystem = "com.paprika"

    public static let smc = Logger(subsystem: subsystem, category: "smc")
    public static let battery = Logger(subsystem: subsystem, category: "battery")
    public static let policy = Logger(subsystem: subsystem, category: "policy")
    public static let daemon = Logger(subsystem: subsystem, category: "daemon")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
