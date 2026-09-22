//
//  Notifier.swift
//  Paprika
//
//  알림 센터로 상태 변화를 알린다.
//
//  주의: ad-hoc 서명으로 직접 빌드한 앱은 알림 권한 요청이 실패할 수 있다.
//  실패해도 앱의 나머지 기능에는 영향이 없도록 전부 안전하게 감쌌다.
//

import Foundation
import PaprikaKit
import UserNotifications

final class Notifier {

    private var isAuthorized = false
    private var didRequestAuthorization = false
    /// 이미 알린 이벤트. 폴링마다 같은 이벤트가 또 와도 중복 알림이 안 나게 한다.
    private var notifiedEventIDs: Set<UUID> = []
    /// 같은 종류의 알림을 연속으로 쏟아내지 않도록 최소 간격을 둔다.
    private var lastNotificationDate: [PaprikaEvent.Kind: Date] = [:]
    private let minimumInterval: TimeInterval = 60

    private var center: UNUserNotificationCenter? {
        // 번들 ID 가 없는 상태(예: 번들 밖에서 실행)에서 current() 를 부르면 크래시한다.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization, let center else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                PaprikaLog.app.error("알림 권한 요청 실패: \(String(describing: error), privacy: .public)")
            }
            DispatchQueue.main.async { self?.isAuthorized = granted }
        }
    }

    /// 새 이벤트를 훑어서 알릴 만한 것만 알린다.
    ///
    /// - Parameter markOnly: 첫 스냅샷처럼 "과거 이벤트"를 받은 경우 true 를 주면
    ///   알림 없이 읽음 처리만 한다. (앱을 켤 때 밀린 알림이 쏟아지지 않게)
    func process(events: [PaprikaEvent], enabled: Bool, markOnly: Bool) {
        for event in events where !notifiedEventIDs.contains(event.id) {
            notifiedEventIDs.insert(event.id)
            guard !markOnly, enabled, event.kind.deservesNotification else { continue }
            guard shouldSend(kind: event.kind) else { continue }
            send(title: title(for: event.kind), body: event.message)
        }

        // 메모리 누수를 막기 위해 오래된 ID 는 버린다.
        if notifiedEventIDs.count > 2000 {
            notifiedEventIDs = Set(events.map(\.id))
        }
    }

    private func shouldSend(kind: PaprikaEvent.Kind) -> Bool {
        let now = Date()
        if let last = lastNotificationDate[kind], now.timeIntervalSince(last) < minimumInterval {
            return false
        }
        lastNotificationDate[kind] = now
        return true
    }

    private func title(for kind: PaprikaEvent.Kind) -> String {
        switch kind {
        case .limitReached: return L.s("충전 상한 도달", "Charge limit reached")
        case .temperatureGuard: return L.s("배터리 온도 보호", "Battery temperature guard")
        case .fullChargeDone: return L.s("100% 충전 완료", "Charged to 100%")
        case .calibrationPhase: return L.s("배터리 캘리브레이션", "Battery calibration")
        case .calibrationFinished: return L.s("캘리브레이션 완료", "Calibration finished")
        case .hardwareError: return L.s("Paprika 오류", "Paprika error")
        default: return "Paprika"
        }
    }

    func send(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                PaprikaLog.app.error("알림 전송 실패: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
