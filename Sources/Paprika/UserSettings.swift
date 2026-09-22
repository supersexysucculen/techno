//
//  UserSettings.swift
//  Paprika
//
//  UI 전용 설정. 충전 동작에 영향을 주는 값은 여기가 아니라 PaprikaConfig(데몬)에 있다.
//

import Combine
import Foundation
import PaprikaKit

final class UserSettings: ObservableObject {

    private enum Key {
        static let language = "paprika.language"
        static let iconStyle = "paprika.iconStyle"
        static let showPercentage = "paprika.showPercentage"
        static let showLimitBadge = "paprika.showLimitBadge"
        static let notificationsEnabled = "paprika.notificationsEnabled"
        static let refreshInterval = "paprika.refreshInterval"
        static let lowBatteryThreshold = "paprika.lowBatteryThreshold"
        static let historyRetentionDays = "paprika.historyRetentionDays"
        static let historySampleSeconds = "paprika.historySampleSeconds"
        static let hasCompletedFirstRun = "paprika.hasCompletedFirstRun"
    }

    private let defaults: UserDefaults

    @Published var language: PaprikaLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            L.language = language
        }
    }

    @Published var iconStyle: MenuBarIconStyle {
        didSet { defaults.set(iconStyle.rawValue, forKey: Key.iconStyle) }
    }

    @Published var showPercentage: Bool {
        didSet { defaults.set(showPercentage, forKey: Key.showPercentage) }
    }

    /// 메뉴바에 "78/80" 처럼 상한도 같이 보여줄지.
    @Published var showLimitBadge: Bool {
        didSet { defaults.set(showLimitBadge, forKey: Key.showLimitBadge) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// 앱이 데몬에게 상태를 물어보는 주기(초).
    @Published var refreshInterval: Double {
        didSet {
            let clamped = max(1, min(30, refreshInterval))
            if clamped != refreshInterval { refreshInterval = clamped; return }
            defaults.set(refreshInterval, forKey: Key.refreshInterval)
        }
    }

    /// 이 아래로 떨어지면 아이콘이 빨간 파프리카가 된다.
    @Published var lowBatteryThreshold: Double {
        didSet {
            let clamped = max(5, min(40, lowBatteryThreshold))
            if clamped != lowBatteryThreshold { lowBatteryThreshold = clamped; return }
            defaults.set(lowBatteryThreshold, forKey: Key.lowBatteryThreshold)
        }
    }

    @Published var historyRetentionDays: Int {
        didSet {
            let clamped = max(1, min(90, historyRetentionDays))
            if clamped != historyRetentionDays { historyRetentionDays = clamped; return }
            defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays)
        }
    }

    @Published var historySampleSeconds: Double {
        didSet {
            let clamped = max(15, min(600, historySampleSeconds))
            if clamped != historySampleSeconds { historySampleSeconds = clamped; return }
            defaults.set(historySampleSeconds, forKey: Key.historySampleSeconds)
        }
    }

    @Published var hasCompletedFirstRun: Bool {
        didSet { defaults.set(hasCompletedFirstRun, forKey: Key.hasCompletedFirstRun) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        language = PaprikaLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        iconStyle = MenuBarIconStyle(rawValue: defaults.string(forKey: Key.iconStyle) ?? "") ?? .pepper
        showPercentage = defaults.object(forKey: Key.showPercentage) as? Bool ?? true
        showLimitBadge = defaults.object(forKey: Key.showLimitBadge) as? Bool ?? false
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        refreshInterval = defaults.object(forKey: Key.refreshInterval) as? Double ?? 4
        lowBatteryThreshold = defaults.object(forKey: Key.lowBatteryThreshold) as? Double ?? 15
        historyRetentionDays = defaults.object(forKey: Key.historyRetentionDays) as? Int ?? 14
        historySampleSeconds = defaults.object(forKey: Key.historySampleSeconds) as? Double ?? 60
        hasCompletedFirstRun = defaults.object(forKey: Key.hasCompletedFirstRun) as? Bool ?? false

        // 저장된 언어를 즉시 적용한다.
        L.language = language
    }
}
