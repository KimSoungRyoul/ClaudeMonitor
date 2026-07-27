//
//  MenuBarRenderer.swift
//  ClaudeMonitor
//
//  메뉴바에 표시할 컬러 이미지를 SwiftUI 뷰 → NSImage 로 렌더링한다.
//  (MenuBarExtra 의 label 로 text 를 쓰면 단색으로만 표시되므로, 컬러를 위해 이미지로 렌더링)
//

import SwiftUI

enum MenuBarRenderer {
    /// 활성 계정의 5h / 7d 사용률을 작은 컬러 라벨 이미지로 만든다.
    @MainActor
    static func render(account: Account?, usage: AccountUsage?) -> NSImage {
        // ImageRenderer 는 렌더 시점의 환경을 고정해 그린다 — 시스템 외형을 명시하지 않으면
        // 다크 모드에서도 라이트용 회색으로 그려진다. (테마가 바뀌면 AppState 가 다시 부른다)
        // NSApp 은 프리뷰 렌더 경로처럼 앱 인스턴스가 아직 없을 때 nil 이라 직접 참조하면 크래시한다.
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let view = MenuBarLabel(account: account, usage: usage)
            .environment(\.colorScheme, isDark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let img = renderer.nsImage else { return fallback() }
        img.isTemplate = false   // 컬러 유지
        img.accessibilityDescription = accessibilityLabel(account: account, usage: usage)
        return img
    }

    /// VoiceOver 용 설명 — 이미지라 라벨이 없으면 "이미지"로만 읽힌다.
    private static func accessibilityLabel(account: Account?, usage: AccountUsage?) -> String {
        var parts: [String] = []
        if let name = account?.displayName { parts.append(name) }
        if let five = usage?.fiveHour {
            parts.append(L.s("5시간 \(Int(five.percentage.rounded()))퍼센트",
                             "5-hour \(Int(five.percentage.rounded())) percent"))
        }
        if let seven = usage?.sevenDay {
            parts.append(L.s("7일 \(Int(seven.percentage.rounded()))퍼센트",
                             "7-day \(Int(seven.percentage.rounded())) percent"))
        }
        for model in usage?.models ?? [] {
            parts.append("\(model.name) \(Int(model.usage.percentage.rounded()))%")
        }
        if parts.isEmpty { return L.s("Claude 사용량", "Claude usage") }
        return parts.joined(separator: ", ")
    }

    private static func fallback() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 16))
        return img
    }
}

/// 메뉴바용 컴팩트 라벨: [아이콘] 5h NN%  7d NN%
private struct MenuBarLabel: View {
    let account: Account?
    let usage: AccountUsage?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gauge.medium")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if let five = usage?.fiveHour {
                segment(tag: "5h", pct: five.percentage, color: Theme.fiveHourColor(five.percentage))
            }
            if let seven = usage?.sevenDay {
                segment(tag: "7d", pct: seven.percentage, color: Theme.sevenDayColor(seven.percentage))
            }
            if usage?.fiveHour == nil, usage?.sevenDay == nil, let extra = usage?.extra, extra.enabled {
                Text(extra.compactUsed)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.extraColor)
            }
            if usage == nil {
                Text("Claude")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 16)
    }

    private func segment(tag: String, pct: Double, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(tag)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(Int(pct.rounded()))%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
    }
}
