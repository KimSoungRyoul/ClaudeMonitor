//
//  WidgetViews.swift
//  ClaudeMonitorWidget
//
//  위젯 패밀리별 뷰: small(단일 계정 듀얼 링), medium(활성 + 추가 계정), large(전체 리스트).
//

import SwiftUI
import ClaudeMonitorShared

/// 원형 게이지 (가운데 % + 캡션)
struct WidgetRing: View {
    let pct: Double
    let color: Color
    var caption: String = ""
    var lineWidth: CGFloat = 7
    var diameter: CGFloat = 64

    private var fraction: Double { min(1, max(0, pct / 100)) }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(gradient: Gradient(colors: [color.opacity(0.55), color]),
                                    center: .center,
                                    startAngle: .degrees(-90),
                                    endAngle: .degrees(-90 + 360 * fraction)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(pct.rounded()))")
                    .font(.system(size: diameter * 0.28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                if !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: diameter * 0.15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// 이름 + 요금제 헤더 한 줄
private struct AccountHeader: View {
    let account: AccountSnapshot
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(WidgetTheme.brand).frame(width: 7, height: 7)
            Text(account.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(account.plan)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// 빈 상태(로그인 필요)
struct WidgetEmptyView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 22))
                .foregroundStyle(WidgetTheme.brand)
            Text("ClaudeMonitor")
                .font(.system(size: 12, weight: .semibold))
            Text("Log in to see usage")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(6)
    }
}

// MARK: - Small

struct SmallWidgetView: View {
    let account: AccountSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AccountHeader(account: account)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                if let p = account.fiveHourPct {
                    ringWithReset(pct: p, reset: account.fiveHourResetsAt,
                                  color: WidgetTheme.fiveHour(p), tag: "5h")
                }
                if let p = account.sevenDayPct {
                    ringWithReset(pct: p, reset: account.sevenDayResetsAt,
                                  color: WidgetTheme.sevenDay(p), tag: "7d")
                }
                if account.fiveHourPct == nil, account.sevenDayPct == nil { extraOrEmpty }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func ringWithReset(pct: Double, reset: Date?, color: Color, tag: String) -> some View {
        VStack(spacing: 2) {
            WidgetRing(pct: pct, color: color, caption: tag, diameter: 58)
            Text(WidgetFmt.remaining(reset, now: now))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var extraOrEmpty: some View {
        if let used = account.extraUsed, let limit = account.extraLimit, limit > 0 {
            WidgetRing(pct: min(100, used / limit * 100), color: WidgetTheme.extra,
                       caption: "extra", diameter: 58)
                .frame(maxWidth: .infinity)
        } else {
            Text("No data").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Medium

struct MediumWidgetView: View {
    let snapshot: UsageSnapshot
    let now: Date

    private var active: AccountSnapshot? { snapshot.activeAccount }
    private var others: [AccountSnapshot] {
        guard let active else { return [] }
        return snapshot.accounts.filter { $0.id != active.id }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let active {
                VStack(alignment: .leading, spacing: 6) {
                    AccountHeader(account: active)
                    HStack(spacing: 10) {
                        if let p = active.fiveHourPct {
                            VStack(spacing: 2) {
                                WidgetRing(pct: p, color: WidgetTheme.fiveHour(p), caption: "5h", diameter: 56)
                                Text(WidgetFmt.remaining(active.fiveHourResetsAt, now: now))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        if let p = active.sevenDayPct {
                            VStack(spacing: 2) {
                                WidgetRing(pct: p, color: WidgetTheme.sevenDay(p), caption: "7d", diameter: 56)
                                Text(WidgetFmt.remaining(active.sevenDayResetsAt, now: now))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(others.prefix(3)) { acc in
                            CompactAccountRow(account: acc)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                WidgetEmptyView()
            }
        }
    }
}

/// 한 줄 요약: 이름 + 5h/7d 바
struct CompactAccountRow: View {
    let account: AccountSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
            HStack(spacing: 6) {
                if let p = account.fiveHourPct { miniBar(p, WidgetTheme.fiveHour(p), "5h") }
                if let p = account.sevenDayPct { miniBar(p, WidgetTheme.sevenDay(p), "7d") }
            }
        }
    }

    private func miniBar(_ pct: Double, _ color: Color, _ tag: String) -> some View {
        HStack(spacing: 3) {
            Text(tag).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(Int(pct.rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Large

struct LargeWidgetView: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(WidgetTheme.brand).frame(width: 8, height: 8)
                Text("Claude usage").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(snapshot.generatedAt, style: .time)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Divider()
            if snapshot.accounts.isEmpty {
                Spacer(); WidgetEmptyView().frame(maxWidth: .infinity); Spacer()
            } else {
                ForEach(snapshot.accounts.prefix(5)) { acc in
                    LargeAccountRow(account: acc, now: now,
                                    isActive: acc.id == snapshot.activeAccountId)
                    if acc.id != snapshot.accounts.prefix(5).last?.id { Divider().opacity(0.4) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct LargeAccountRow: View {
    let account: AccountSnapshot
    let now: Date
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? WidgetTheme.brand : Color.secondary.opacity(0.3))
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(account.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(account.plan).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let p = account.fiveHourPct {
                        label("5h", p, WidgetTheme.fiveHour(p), reset: account.fiveHourResetsAt)
                    }
                    if let p = account.sevenDayPct {
                        label("7d", p, WidgetTheme.sevenDay(p), reset: account.sevenDayResetsAt)
                    }
                }
            }
            Spacer()
            if let p = account.primaryPct {
                Text("\(Int(p.rounded()))%")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(account.fiveHourPct != nil ? WidgetTheme.fiveHour(p) : WidgetTheme.sevenDay(p))
            }
        }
    }

    private func label(_ tag: String, _ pct: Double, _ color: Color, reset: Date?) -> some View {
        HStack(spacing: 3) {
            Text(tag).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(Int(pct.rounded()))%").font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text("· \(WidgetFmt.remaining(reset, now: now))")
                .font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }
}
