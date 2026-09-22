//
//  Localization.swift
//  PaprikaKit
//
//  .strings 번들을 따로 굴리는 대신, 한국어/영어 두 개만 코드에 직접 넣었다.
//  개인용 앱이라 이게 가장 사고가 없다.
//
//  사용법:  L.s("충전 제한", "Charge limit")
//

import Foundation

public enum PaprikaLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case korean
    case english

    public var label: String {
        switch self {
        case .system: return L.s("시스템 설정 따라가기", "Follow system")
        case .korean: return "한국어"
        case .english: return "English"
        }
    }
}

/// 아주 얇은 로컬라이제이션 게이트.
public enum L {
    /// 사용자가 고른 언어. 앱이 시작할 때, 설정이 바뀔 때 갱신한다.
    public static var language: PaprikaLanguage = .system

    /// 실제로 적용될 언어(system 이면 OS 설정에서 판단).
    public static var resolved: PaprikaLanguage {
        switch language {
        case .korean: return .korean
        case .english: return .english
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("ko") ? .korean : .english
        }
    }

    public static var isKorean: Bool { resolved == .korean }

    /// 한국어/영어 문자열 중 하나를 고른다.
    public static func s(_ korean: String, _ english: String) -> String {
        isKorean ? korean : english
    }
}
