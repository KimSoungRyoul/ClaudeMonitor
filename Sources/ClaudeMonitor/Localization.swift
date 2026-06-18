//
//  Localization.swift
//  ClaudeMonitor
//
//  경량 로컬라이제이션. 호출부에서 L.s("한국어", "English") 형태로 두 언어를 같이 둔다.
//  현재 언어는 AppState.language(AppLanguage) → L.lang 으로 동기화한다.
//

import Foundation

/// 사용자가 고르는 언어 설정
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system, en, ko
    var id: String { rawValue }

    /// 실제 적용 언어(시스템이면 OS 설정에서 추정)
    var resolved: Lang {
        switch self {
        case .system:
            let pref = Locale.preferredLanguages.first ?? "en"
            return pref.hasPrefix("ko") ? .ko : .en
        case .en: return .en
        case .ko: return .ko
        }
    }

    /// 설정 피커에 표시할 라벨
    var label: String {
        switch self {
        case .system: return L.s("시스템", "System")
        case .en: return "English"
        case .ko: return "한국어"
        }
    }
}

enum Lang { case en, ko }

/// 문자열 헬퍼
enum L {
    static var lang: Lang = .ko

    /// 한/영 중 현재 언어 문자열 반환
    static func s(_ ko: String, _ en: String) -> String { lang == .ko ? ko : en }

    static var locale: Locale { lang == .ko ? Locale(identifier: "ko_KR") : Locale(identifier: "en_US") }
}
