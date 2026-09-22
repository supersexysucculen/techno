//
//  SettingsWindow.swift
//  Paprika
//
//  SwiftUI 의 Settings 씬은 버전마다 여는 방법이 달라서(showSettingsWindow: /
//  showPreferencesWindow:) 메뉴바 전용 앱에서 다루기가 번거롭다.
//  그래서 NSWindow 를 직접 만들어 SwiftUI 뷰를 담는다. 동작이 예측 가능하다.
//

import AppKit
import PaprikaKit
import SwiftUI

/// 메인 스레드에서만 호출한다(SwiftUI 버튼 액션에서만 쓰인다).
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            bringToFront(window)
            return
        }

        let hosting = NSHostingView(
            rootView: SettingsView()
                .environmentObject(model)
        )

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = L.s("Paprika 설정", "Paprika Settings")
        newWindow.contentView = hosting
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()
        _ = newWindow.setFrameAutosaveName("PaprikaSettingsWindow")

        window = newWindow
        bringToFront(newWindow)
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 닫으면 참조를 놓아서 다음에 새로 만든다(설정 값이 항상 최신으로 반영된다).
        window = nil
    }
}
