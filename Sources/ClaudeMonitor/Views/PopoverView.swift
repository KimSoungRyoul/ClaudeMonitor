//
//  PopoverView.swift
//  ClaudeMonitor
//
//  메뉴바 클릭 시 나타나는 메인 팝오버. 활성 계정 상세 + 멀티계정 리스트.
//

import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var state: AppState

    /// 본문 실제 높이 (ScrollView 가 fit-to-content 윈도우에서 0 으로 접히는 것을 막기 위해 측정)
    @State private var bodyHeight: CGFloat = 0
    private let maxBodyHeight: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                UsageSections()
                    .padding(14)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: BodyHeightKey.self, value: g.size.height)
                        }
                    )
            }
            .frame(height: min(max(bodyHeight, 160), maxBodyHeight))
            .onPreferenceChange(BodyHeightKey.self) { bodyHeight = $0 }
            footer
        }
        .frame(width: 360)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            BrandIconView(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.activeAccount?.displayName ?? "ClaudeMonitor")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let plan = state.activeAccount?.plan { PlanBadge(plan: plan) }
                    if state.demoMode {
                        Text(L.s("데모", "Demo"))
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button { Task { await state.refreshAll() } } label: {
                    circleIcon("arrow.clockwise")
                        .rotationEffect(.degrees(state.isRefreshing ? 360 : 0))
                        .animation(state.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: state.isRefreshing)
                }
                .buttonStyle(.plain)
                .help(L.s("새로고침", "Refresh"))

                Menu {
                    Button(L.s("Claude 계정 추가/로그인…", "Add Claude account / Log in…")) { WindowManager.shared.openLogin() }
                    Button(L.s("설정…", "Settings…")) { WindowManager.shared.openSettings() }
                    Divider()
                    Toggle(L.s("데모 모드", "Demo mode"), isOn: Binding(
                        get: { state.demoMode },
                        set: { state.demoMode = $0; state.rebuildMenuBarImage() }))
                    Divider()
                    Button(L.s("종료", "Quit")) { NSApplication.shared.terminate(nil) }
                } label: {
                    circleIcon("ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L.s("메뉴", "Menu"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// 헤더용 원형 아이콘 버튼 (탭 영역 + 겹침 방지)
    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.primary.opacity(0.06)))
            .contentShape(Circle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(state.isRefreshing ? Color.orange : Color.green).frame(width: 6, height: 6)
            if let updated = state.lastUpdated {
                Text(L.s("업데이트 \(TimeFmt.timeString(updated))", "Updated \(TimeFmt.timeString(updated))"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if state.demoMode {
                Text(L.s("데모 데이터 — 메뉴 ‘…’에서 로그인", "Demo data — log in from the ‘…’ menu"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(L.s("새로고침 필요", "Refresh needed")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if let rel = state.updateAvailable {
                Button {
                    if let url = URL(string: rel.htmlURL) { NSWorkspace.shared.open(url) }
                } label: {
                    Text(L.s("새 버전 \(rel.tag) ↗", "Update \(rel.tag) ↗"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xD97757))
                }
                .buttonStyle(.plain)
                .help(L.s("새 버전 다운로드", "Download update"))
            } else {
                Text("ClaudeMonitor \(state.appVersion)").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.thinMaterial)
    }
}

/// 본문 높이 측정용 PreferenceKey
private struct BodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 멀티계정 리스트의 한 행
struct AccountRow: View {
    let account: Account
    let usage: AccountUsage?
    let error: String?
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            // 좌측 컬러 인디케이터
            RoundedRectangle(cornerRadius: 2)
                .fill(indicatorColor)
                .frame(width: 3, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(account.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    PlanBadge(plan: account.plan)
                }
                subtitle
            }
            Spacer(minLength: 6)
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
            }
            ringsView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Theme.cardBackground.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    /// 이름 아래 보조 줄: 각 한도 리셋 날짜·시간 (언제까지인지) + 추가 사용액
    @ViewBuilder
    private var subtitle: some View {
        if let error {
            Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1)
        } else if usage == nil {
            Text(L.s("불러오는 중…", "Loading…")).font(.system(size: 10)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                if let five = usage?.fiveHour, let reset = five.resetsAt {
                    resetLine(icon: "clock", color: Theme.fiveHourColor(five.percentage),
                              text: TimeFmt.resetShort(reset), resetsAt: reset, longCycle: false)
                }
                if let seven = usage?.sevenDay, let reset = seven.resetsAt {
                    resetLine(icon: "calendar", color: Theme.sevenDayColor(seven.percentage),
                              text: TimeFmt.resetLong(reset), resetsAt: reset, longCycle: true)
                }
                if let extra = usage?.extra, extra.enabled {
                    resetLine(icon: "creditcard", color: Theme.extraColor, text: extra.fullText, resetsAt: nil)
                }
            }
        }
    }

    /// 보조 줄 한 항목: 아이콘 + 리셋 시각(회색) + 남은 시간(주기별 색상 규칙)
    @ViewBuilder
    private func resetLine(icon: String, color: Color, text: String, resetsAt: Date?, longCycle: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 10)
            if let resetsAt {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    (Text(text + "  ").foregroundColor(.secondary)
                        + Text(TimeFmt.remainingCompact(resetsAt, now: ctx.date) + L.s(" 남음", " left"))
                            .foregroundColor(TimeFmt.remainingColor(resetsAt, longCycle: longCycle, now: ctx.date)))
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                }
            } else {
                Text(text)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// 행 우측: 5시간 + 7일 미니 원형 게이지 (둘 다 표시)
    @ViewBuilder
    private var ringsView: some View {
        if error != nil || usage == nil {
            MiniRingEmpty()
        } else {
            HStack(spacing: 6) {
                ForEach(accountRings) { r in
                    MiniRing(percentage: r.pct, color: r.color, caption: r.tag)
                }
            }
        }
    }

    /// 행에 표시할 링 목록 (5h, 7d; 둘 다 없으면 Extra$)
    private var accountRings: [RingSpec] {
        var arr: [RingSpec] = []
        if let five = usage?.fiveHour {
            arr.append(RingSpec(tag: "5h", pct: five.percentage, color: Theme.fiveHourColor(five.percentage)))
        }
        if let seven = usage?.sevenDay {
            arr.append(RingSpec(tag: "7d", pct: seven.percentage, color: Theme.sevenDayColor(seven.percentage)))
        }
        if arr.count < 2, let extra = usage?.extra, extra.enabled {
            arr.append(RingSpec(tag: "$", pct: extra.percentage, color: Theme.extraColor))
        }
        return arr
    }

    private var indicatorColor: Color {
        if let p = usage?.primary?.percentage { return Theme.fiveHourColor(p) }
        if let extra = usage?.extra, extra.enabled { return Theme.extraColor }
        return Color.secondary.opacity(0.4)
    }
}

/// 계정 행 미니 링 1개의 스펙
private struct RingSpec: Identifiable {
    let tag: String
    let pct: Double
    let color: Color
    var id: String { tag }
}
