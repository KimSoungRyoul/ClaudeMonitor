//
//  Theme.swift
//  ClaudeMonitor
//
//  색상 팔레트, 한도별 컬러 스킴, 시간 포맷 유틸.
//

import SwiftUI

enum Theme {
    /// 5시간 한도 색상 (사용률에 따라 green → orange → red)
    static func fiveHourColor(_ pct: Double) -> Color {
        switch pct {
        case ..<50: return Color(hex: 0x34C759)   // green
        case ..<75: return Color(hex: 0xFFCC00)   // yellow
        case ..<90: return Color(hex: 0xFF9500)   // orange
        default:    return Color(hex: 0xFF3B30)   // red
        }
    }

    /// 7일 한도 색상 (보라 계열)
    static func sevenDayColor(_ pct: Double) -> Color {
        switch pct {
        case ..<50: return Color(hex: 0xC084FC)
        case ..<85: return Color(hex: 0xB450F0)
        default:    return Color(hex: 0xB41EA0)
        }
    }

    /// Opus 색상 (틸)
    static let opusColor = Color(hex: 0x14B8A6)
    /// Sonnet 색상 (인디고)
    static let sonnetColor = Color(hex: 0x6366F1)
    /// Extra Usage 색상 (앰버)
    static let extraColor = Color(hex: 0xF59E0B)

    /// 큰 링에 쓰는 그라데이션
    static func ringGradient(_ pct: Double, base: (Double) -> Color) -> AngularGradient {
        let c = base(pct)
        return AngularGradient(
            gradient: Gradient(colors: [c.opacity(0.65), c]),
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.6)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// SwiftUI Color → NSColor (메뉴바 이미지 렌더링용)
    var nsColor: NSColor { NSColor(self) }
}

// MARK: - 시간 포맷

enum TimeFmt {
    /// 5시간 한도용: "오늘 오후 5:10" / "Today 5:10 PM"
    static func resetShort(_ date: Date?) -> String {
        guard let date else { return L.s("사용 시작 후 표시", "Shown after first use") }
        let cal = Calendar.current
        let time = timeString(date)
        if cal.isDateInToday(date) { return "\(L.s("오늘", "Today")) \(time)" }
        if cal.isDateInTomorrow(date) { return "\(L.s("내일", "Tomorrow")) \(time)" }
        let df = DateFormatter()
        df.locale = L.locale
        df.setLocalizedDateFormatFromTemplate(L.lang == .ko ? "Md" : "MMMd")
        return "\(df.string(from: date)) \(time)"
    }

    /// 7일 한도용: "6월 20일 오후 7시" / "Jun 20, 7 PM"
    static func resetLong(_ date: Date?) -> String {
        guard let date else { return L.s("사용 시작 후 표시", "Shown after first use") }
        let df = DateFormatter()
        df.locale = L.locale
        if L.lang == .ko {
            df.dateFormat = "M월 d일 a h시"
        } else {
            df.setLocalizedDateFormatFromTemplate("MMMd")
            return "\(df.string(from: date)), \(hourString(date))"
        }
        return df.string(from: date)
    }

    /// "오후 5:10" / "5:10 PM"
    static func timeString(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = L.locale
        df.dateFormat = L.lang == .ko ? "a h:mm" : "h:mm a"
        return df.string(from: date)
    }

    /// "오후 7시" / "7 PM"
    private static func hourString(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = L.locale
        df.dateFormat = L.lang == .ko ? "a h시" : "h a"
        return df.string(from: date)
    }

    /// 남은 시간: "2시간 30분 남음" / "2h 30m left"
    static func remaining(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "-" }
        let secs = date.timeIntervalSince(now)
        guard secs > 0 else { return L.s("곧 리셋", "resetting soon") }
        let totalMin = Int(ceil(secs / 60))
        let days = totalMin / (60 * 24)
        let hours = (totalMin % (60 * 24)) / 60
        let mins = totalMin % 60
        if days > 0 { return L.s("\(days)일 \(hours)시간 남음", "\(days)d \(hours)h left") }
        if hours > 0 { return L.s("\(hours)시간 \(mins)분 남음", "\(hours)h \(mins)m left") }
        return L.s("\(mins)분 남음", "\(mins)m left")
    }

    /// 남은 시간 컴팩트: "2시간 30분" / "2h 30m"
    static func remainingCompact(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "-" }
        let secs = date.timeIntervalSince(now)
        guard secs > 0 else { return L.s("곧 리셋", "soon") }
        let totalMin = Int(ceil(secs / 60))
        let days = totalMin / (60 * 24)
        let hours = (totalMin % (60 * 24)) / 60
        let mins = totalMin % 60
        if days > 0 { return L.s("\(days)일 \(hours)시간", "\(days)d \(hours)h") }
        if hours > 0 { return L.s("\(hours)시간 \(mins)분", "\(hours)h \(mins)m") }
        return L.s("\(mins)분", "\(mins)m")
    }

    /// 남은 시간 색상.
    /// - 5시간 한도(longCycle=false): 1시간 미만 빨강, 그 외 초록
    /// - 7일 한도(longCycle=true): 1일 미만 빨강, 2일 미만 노랑, 그 외 초록
    static func remainingColor(_ date: Date?, longCycle: Bool = false, now: Date = Date()) -> Color {
        guard let date else { return .secondary }
        let secs = date.timeIntervalSince(now)
        let red = Color(hex: 0xFF3B30)
        let green = Color(hex: 0x34C759)
        if longCycle {
            let day = 86_400.0
            if secs < day { return red }            // 1일 미만 → 빨강
            if secs < 2 * day { return Color(hex: 0xE0A500) }  // 2일 미만 → 노랑
            return green
        } else {
            return secs < 3600 ? red : green        // 1시간 미만 → 빨강
        }
    }
}
