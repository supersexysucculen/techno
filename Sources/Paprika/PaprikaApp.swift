//
//  PaprikaApp.swift
//  Paprika
//
//  메뉴바 전용 앱. Dock 아이콘도, 메뉴바 메뉴도 없다(LSUIElement).
//

import AppKit
import PaprikaKit
import SwiftUI

@main
struct PaprikaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuRootView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 메뉴바에 실제로 보이는 부분.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: model.menuBarIcon)
            if let text = model.menuBarText {
                Text(text)
                    .monospacedDigit()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock 에 뜨지 않게 한다. Info.plist 의 LSUIElement 와 이중 안전장치.
        NSApp.setActivationPolicy(.accessory)

        guard !terminateIfAlreadyRunning() else { return }

        // .icns 를 따로 만들지 않는다. LSUIElement 앱은 Dock 에 안 뜨지만,
        // 알림과 시스템 대화상자에는 앱 아이콘이 쓰이므로 코드로 그려서 넣는다.
        NSApp.applicationIconImage = PepperIconRenderer.appIcon(size: 512)

        PaprikaLog.app.notice("Paprika 앱 시작 (v\(PaprikaVersion.current, privacy: .public))")
        AppModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
        PaprikaLog.app.notice("Paprika 앱 종료")
    }

    /// 두 번 실행되는 것을 막는다. (로그인 항목 + 수동 실행이 겹치는 경우)
    private func terminateIfAlreadyRunning() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        // 자기 자신을 제외하고 더 오래된 인스턴스가 있으면 이쪽이 물러난다.
        let others = running.filter { $0.processIdentifier != getpid() }
        guard !others.isEmpty else { return false }

        PaprikaLog.app.notice("이미 실행 중인 Paprika 가 있어 종료합니다.")
        others.first?.activate(options: [])
        NSApp.terminate(nil)
        return true
    }
}
