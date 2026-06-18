//
//  UsageSections.swift
//  ClaudeMonitor
//
//  팝오버 본문(스크롤 영역 안의 내용): 큰 링 + 한도 카드 + 멀티계정 리스트.
//  PopoverView 와 PreviewRenderer 가 공유한다.
//

import SwiftUI

struct UsageSections: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            heroSection
            limitsSection
            accountsSection
        }
    }

    // MARK: - Hero (큰 링)

    @ViewBuilder
    private var heroSection: some View {
        let usage = state.activeUsage
        let five = usage?.fiveHour
        let seven = usage?.sevenDay

        if five != nil || seven != nil {
            // 5시간 / 7일 한도를 컴팩트한 원형 게이지 2개로 (리셋 시간 포함)
            HStack(alignment: .top, spacing: 12) {
                if let five {
                    ringColumn(pct: five.percentage, color: Theme.fiveHourColor(five.percentage),
                               title: L.s("5시간", "5-hour"), reset: five.resetsAt, long: false)
                }
                if let seven {
                    ringColumn(pct: seven.percentage, color: Theme.sevenDayColor(seven.percentage),
                               title: L.s("7일", "7-day"), reset: seven.resetsAt, long: true)
                }
            }
            .padding(.top, 2)
        } else if let extra = usage?.extra, extra.enabled {
            RingGauge(percentage: extra.percentage, color: Theme.extraColor,
                      lineWidth: 10, diameter: 116, caption: L.s("추가 사용량", "Extra usage"))
                .padding(.top, 2)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.secondary)
                Text(L.s("사용량 데이터 없음", "No usage data")).font(.system(size: 12)).foregroundStyle(.secondary)
                if let err = state.activeAccount.flatMap({ state.errors[$0.id] }) {
                    Text(err).font(.system(size: 10)).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .frame(height: 120)
        }
    }

    /// 히어로의 한 컬럼: 원형 게이지 + 라벨 + 리셋시간/남은시간
    private func ringColumn(pct: Double, color: Color, title: String, reset: Date?, long: Bool) -> some View {
        VStack(spacing: 5) {
            RingGauge(percentage: pct, color: color, lineWidth: 9, diameter: 104, caption: title)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(spacing: 1) {
                    Text(long ? TimeFmt.resetLong(reset) : TimeFmt.resetShort(reset))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(TimeFmt.remaining(reset, now: ctx.date))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TimeFmt.remainingColor(reset, longCycle: long, now: ctx.date))
                }
                .multilineTextAlignment(.center)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 한도 카드

    @ViewBuilder
    private var limitsSection: some View {
        // 5시간/7일은 히어로 듀얼 링이 대신하므로, 여기선 Opus/Sonnet/Extra 만 카드로.
        let usage = state.activeUsage
        VStack(spacing: 8) {
            if let opus = usage?.opus {
                LimitCard(icon: "brain.head.profile", title: L.s("7일 Opus", "7-day Opus"), limit: opus, color: Theme.opusColor)
            }
            if let sonnet = usage?.sonnet {
                LimitCard(icon: "waveform", title: L.s("7일 Sonnet", "7-day Sonnet"), limit: sonnet, color: Theme.sonnetColor)
            }
            if let extra = usage?.extra, extra.enabled {
                extraCard(extra)
            }
        }
    }

    private func extraCard(_ extra: ExtraUsage) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.extraColor.opacity(0.16)).frame(width: 24, height: 24)
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.extraColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L.s("추가 사용량", "Extra usage")).font(.system(size: 12, weight: .semibold))
                    Text(extra.fullText).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(extra.compactUsed)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.extraColor)
            }
            UsageBar(percentage: extra.percentage, color: Theme.extraColor)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardBackground))
    }

    // MARK: - 계정 리스트

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.s("CLAUDE 계정", "CLAUDE ACCOUNTS"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Text(L.s("\(state.accounts.count)개", "\(state.accounts.count)"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            VStack(spacing: 6) {
                ForEach(state.accounts) { account in
                    AccountRow(account: account,
                               usage: state.usage(for: account),
                               error: state.errors[account.id],
                               isActive: account.id == state.activeAccount?.id)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { state.setActive(account) } }
                }
            }
        }
    }
}
