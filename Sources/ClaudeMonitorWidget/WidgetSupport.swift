//
//  WidgetSupport.swift
//  ClaudeMonitorWidget
//
//  위젯에서 쓰는 색상/포맷 헬퍼. 앱의 Theme 와 동일한 임계치 규칙을 위젯 모듈에 복제한다
//  (위젯은 앱 타깃을 의존하지 않고 ClaudeMonitorShared 만 의존하므로).
//

import SwiftUI

enum WidgetTheme {
    /// 5시간 한도 색상 (green → yellow → orange → red)
    static func fiveHour(_ pct: Double) -> Color {
        switch pct {
        case ..<50: return Color(hex: 0x34C759)
        case ..<75: return Color(hex: 0xFFCC00)
        case ..<90: return Color(hex: 0xFF9500)
        default:    return Color(hex: 0xFF3B30)
        }
    }

    /// 7일 한도 색상 (보라 계열)
    static func sevenDay(_ pct: Double) -> Color {
        switch pct {
        case ..<50: return Color(hex: 0xC084FC)
        case ..<85: return Color(hex: 0xB450F0)
        default:    return Color(hex: 0xB41EA0)
        }
    }

    static let extra = Color(hex: 0xF59E0B)
    static let brand = Color(hex: 0xD97757)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

enum WidgetFmt {
    /// 남은 시간 컴팩트: "2h 30m" / "3d 4h" / "소진"
    static func remaining(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let secs = date.timeIntervalSince(now)
        guard secs > 0 else { return "soon" }
        let totalMin = Int((secs / 60).rounded(.up))
        let days = totalMin / (60 * 24)
        let hours = (totalMin % (60 * 24)) / 60
        let mins = totalMin % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}
