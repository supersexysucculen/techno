//
//  LoginItem.swift
//  Paprika
//
//  로그인 시 자동 실행.
//
//  1순위: SMAppService.mainApp (macOS 13+, 시스템 설정 → 로그인 항목에 노출됨)
//  2순위: ~/Library/LaunchAgents 에 plist 직접 설치
//
//  왜 폴백이 필요한가: SMAppService 는 앱이 제대로 서명·배치돼 있어야 동작한다.
//  직접 빌드해서 ad-hoc 서명만 한 앱에서는 실패할 수 있는데, LaunchAgent 방식은
//  그런 조건이 없다.
//

import Foundation
import PaprikaKit
import ServiceManagement

enum LoginItemMethod: String {
    case serviceManagement
    case launchAgent
    case none
}

enum LoginItem {

    /// 현재 자동 실행이 켜져 있는가.
    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: PaprikaPaths.loginAgentPlist)
    }

    static var activeMethod: LoginItemMethod {
        if SMAppService.mainApp.status == .enabled { return .serviceManagement }
        if FileManager.default.fileExists(atPath: PaprikaPaths.loginAgentPlist) { return .launchAgent }
        return .none
    }

    /// - Returns: 성공하면 nil, 실패하면 사용자에게 보여줄 메시지.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        if enabled {
            // 두 방식이 동시에 걸려 앱이 두 번 뜨는 일을 막는다.
            removeLaunchAgent()
            do {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
                return nil
            } catch {
                PaprikaLog.app.error("SMAppService 등록 실패, LaunchAgent 로 대체합니다: \(String(describing: error), privacy: .public)")
                return installLaunchAgent()
            }
        } else {
            var problems: [String] = []
            if SMAppService.mainApp.status == .enabled {
                do {
                    try SMAppService.mainApp.unregister()
                } catch {
                    problems.append(String(describing: error))
                }
            }
            removeLaunchAgent()
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }
    }

    // MARK: LaunchAgent 폴백

    private static func installLaunchAgent() -> String? {
        let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plistPath = PaprikaPaths.loginAgentPlist
        let directory = (plistPath as NSString).deletingLastPathComponent

        let plist: [String: Any] = [
            "Label": PaprikaPaths.loginItemLabel,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]

        do {
            if !FileManager.default.fileExists(atPath: directory) {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            bootstrapLaunchAgent(plistPath: plistPath)
            return nil
        } catch {
            return L.s("로그인 항목 등록에 실패했습니다: ", "Could not register the login item: ")
                + String(describing: error)
        }
    }

    private static func removeLaunchAgent() {
        let plistPath = PaprikaPaths.loginAgentPlist
        guard FileManager.default.fileExists(atPath: plistPath) else { return }
        runLaunchctl(["bootout", "gui/\(getuid())/\(PaprikaPaths.loginItemLabel)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    private static func bootstrapLaunchAgent(plistPath: String) {
        // 이미 등록돼 있으면 bootstrap 이 실패하므로 먼저 떼어낸다.
        runLaunchctl(["bootout", "gui/\(getuid())/\(PaprikaPaths.loginItemLabel)"])
        runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath])
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            PaprikaLog.app.error("launchctl 실행 실패: \(String(describing: error), privacy: .public)")
            return -1
        }
    }
}
