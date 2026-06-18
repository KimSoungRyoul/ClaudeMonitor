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
        let view = MenuBarLabel(account: account, usage: usage)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let img = renderer.nsImage else { return fallback() }
        img.isTemplate = false   // 컬러 유지
        return img
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
