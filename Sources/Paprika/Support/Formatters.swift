//
//  Formatters.swift
//  Paprika
//

import Foundation
import PaprikaKit

enum Fmt {

    static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f W", value)
    }

    static func signedWatts(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%+.1f W", value)
    }

    static func volts(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.2f V", value)
    }

    static func amps(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%+.2f A", value)
    }

    static func celsius(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f °C", value)
    }

    static func mAh(_ value: Int) -> String {
        guard value > 0 else { return "–" }
        return "\(value) mAh"
    }

    /// 분을 "3시간 12분" 형태로.
    static func duration(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "–" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return L.s("\(remainder)분", "\(remainder) min") }
        if remainder == 0 { return L.s("\(hours)시간", "\(hours) h") }
        return L.s("\(hours)시간 \(remainder)분", "\(hours) h \(remainder) min")
    }

    static func duration(seconds: TimeInterval) -> String {
        duration(minutes: Int(seconds / 60))
    }

    static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = L.isKorean ? Locale(identifier: "ko_KR") : Locale(identifier: "en_US")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func uptime(since date: Date) -> String {
        duration(seconds: Date().timeIntervalSince(date))
    }
}
