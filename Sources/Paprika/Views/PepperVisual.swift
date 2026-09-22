//
//  PepperVisual.swift
//  Paprika
//
//  "지금 상태"를 색과 모양으로 바꾸는 규칙을 한곳에 모았다.
//  메뉴바 아이콘과 팝오버 게이지가 같은 규칙을 쓴다.
//

import AppKit
import PaprikaKit
import SwiftUI

/// 아이콘이 표현하는 상태.
enum PepperVisualState: Equatable {
    /// 충전 중
    case charging
    /// 상한에 도달해 유지 중
    case holding
    /// 배터리로 사용 중
    case onBattery
    /// 강제 방전 중
    case forcedDischarge
    /// 온도 보호로 멈춤
    case tooHot
    /// 관리하지 않음 (기능 끔 / 일시중지)
    case unmanaged
    /// 배터리 잔량 부족
    case low
    /// 데몬과 연결되지 않음
    case disconnected

    var accentColor: Color {
        switch self {
        case .charging: return Color(red: 0.31, green: 0.78, blue: 0.35)      // 초록 파프리카
        case .holding: return Color(red: 0.99, green: 0.76, blue: 0.18)       // 노란 파프리카
        case .onBattery: return Color(red: 0.98, green: 0.58, blue: 0.16)     // 주황 파프리카
        case .forcedDischarge: return Color(red: 0.36, green: 0.62, blue: 0.96)
        case .tooHot: return Color(red: 0.94, green: 0.33, blue: 0.26)
        case .unmanaged: return Color.secondary
        case .low: return Color(red: 0.90, green: 0.22, blue: 0.21)           // 빨간 파프리카
        case .disconnected: return Color.secondary
        }
    }

    /// 메뉴바 아이콘용 색.
    ///
    /// SwiftUI 의 `Color.secondary` 같은 계층형(semantic hierarchical) 스타일을
    /// `NSColor(_:)` 로 바꾼 뒤 `.cgColor` 를 꺼내면, appearance 문맥 밖에서는
    /// 검정이 되거나 실패할 수 있다. 그래서 여기서는 구체적인 NSColor 만 돌려준다.
    var nsAccentColor: NSColor {
        switch self {
        case .charging: return NSColor(calibratedRed: 0.31, green: 0.78, blue: 0.35, alpha: 1)
        case .holding: return NSColor(calibratedRed: 0.99, green: 0.76, blue: 0.18, alpha: 1)
        case .onBattery: return NSColor(calibratedRed: 0.98, green: 0.58, blue: 0.16, alpha: 1)
        case .forcedDischarge: return NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.96, alpha: 1)
        case .tooHot: return NSColor(calibratedRed: 0.94, green: 0.33, blue: 0.26, alpha: 1)
        case .low: return NSColor(calibratedRed: 0.90, green: 0.22, blue: 0.21, alpha: 1)
        case .unmanaged, .disconnected: return NSColor.secondaryLabelColor.usingColorSpace(.sRGB)
            ?? NSColor(calibratedWhite: 0.55, alpha: 1)
        }
    }

    /// 몸통 안에 겹쳐 그릴 작은 기호. nil 이면 그리지 않는다.
    var overlaySymbol: String? {
        switch self {
        case .charging: return "bolt.fill"
        case .holding: return "pause.fill"
        case .tooHot: return "thermometer"
        case .forcedDischarge: return "arrow.down"
        case .unmanaged: return nil
        case .low: return "exclamationmark"
        case .disconnected: return "questionmark"
        case .onBattery: return nil
        }
    }

    var label: String {
        switch self {
        case .charging: return L.s("충전 중", "Charging")
        case .holding: return L.s("상한 유지", "Holding")
        case .onBattery: return L.s("배터리 사용", "On battery")
        case .forcedDischarge: return L.s("강제 방전", "Discharging")
        case .tooHot: return L.s("과열 보호", "Too hot")
        case .unmanaged: return L.s("관리 안 함", "Unmanaged")
        case .low: return L.s("잔량 부족", "Low battery")
        case .disconnected: return L.s("도우미 연결 안 됨", "Helper not connected")
        }
    }

    /// 스냅샷에서 상태를 유도한다.
    static func from(snapshot: PaprikaSnapshot?, lowThreshold: Double = 15) -> PepperVisualState {
        guard let snapshot else { return .disconnected }

        if snapshot.decision.reason == .temperatureGuard { return .tooHot }

        switch snapshot.decision.action {
        case .forceDischarge:
            return .forcedDischarge
        case .inhibitCharging:
            return .holding
        case .unmanaged:
            if !snapshot.battery.isPluggedIn, snapshot.displayPercent <= lowThreshold { return .low }
            return .unmanaged
        case .allowCharging:
            if snapshot.battery.isCharging { return .charging }
            if !snapshot.battery.isPluggedIn {
                return snapshot.displayPercent <= lowThreshold ? .low : .onBattery
            }
            return .charging
        }
    }
}

/// 메뉴바 아이콘 스타일.
enum MenuBarIconStyle: String, Codable, CaseIterable {
    /// 직접 그린 파프리카 (충전량만큼 채워짐)
    case pepper
    /// 단색 템플릿 파프리카 (다크/라이트 자동)
    case pepperMonochrome
    /// 이모지 🫑
    case emoji
    /// 퍼센트 숫자만
    case textOnly

    var label: String {
        switch self {
        case .pepper: return L.s("컬러 파프리카", "Colour pepper")
        case .pepperMonochrome: return L.s("단색 파프리카", "Monochrome pepper")
        case .emoji: return L.s("이모지 🫑", "Emoji 🫑")
        case .textOnly: return L.s("퍼센트만", "Percentage only")
        }
    }
}
