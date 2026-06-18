//
//  Components.swift
//  ClaudeMonitor
//
//  재사용 비주얼 컴포넌트: 링 게이지, 진행 막대, 배지 등.
//

import SwiftUI

/// 번들된 브랜드 아이콘 (헤더 등에 사용)
/// 주의: Bundle.module 은 손수 조립한 .app 에서 못 찾으면 fatalError 로 크래시한다.
/// 따라서 Bundle.module 을 쓰지 않고 가능한 경로들을 안전하게 탐색하고, 못 찾으면 nil 을 반환한다.
enum Brand {
    static let appIcon: NSImage? = {
        // 1) 메인 번들 리소스 (릴리즈 .app: Contents/Resources/AppIconImage.png)
        if let url = Bundle.main.url(forResource: "AppIconImage", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // 2) SwiftPM 리소스 번들 (디버그 raw 바이너리: <exe dir>/ClaudeMonitor_ClaudeMonitor.bundle/…)
        let bundleName = "ClaudeMonitor_ClaudeMonitor.bundle"
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r) }
        dirs.append(Bundle.main.bundleURL)
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() { dirs.append(exe) }
        for d in dirs {
            let u = d.appendingPathComponent(bundleName).appendingPathComponent("AppIconImage.png")
            if FileManager.default.fileExists(atPath: u.path), let img = NSImage(contentsOf: u) {
                return img
            }
        }
        return nil   // 못 찾으면 플레이스홀더 사용 (크래시하지 않음)
    }()
}

/// 브랜드 아이콘 뷰 — 번들 이미지 우선, 없으면 플레이스홀더(주황 그라데이션 + sparkle)
struct BrandIconView: View {
    var size: CGFloat = 30
    var body: some View {
        if let img = Brand.appIcon {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xD97757), Color(hex: 0xC15F3C)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }
}

/// 큰 원형 게이지 (가운데에 % 표시)
struct RingGauge: View {
    let percentage: Double
    let color: Color
    var lineWidth: CGFloat = 14
    var diameter: CGFloat = 150
    var caption: String = ""

    private var fraction: Double { min(1, max(0, percentage / 100)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [color.opacity(0.55), color]),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * fraction)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: fraction)

            VStack(spacing: 2) {
                Text("\(Int(percentage.rounded()))%")
                    .font(.system(size: diameter * 0.26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.system(size: diameter * 0.085, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// 계정 행 우측에 들어가는 작은 원형 게이지 (가운데 % 숫자)
struct MiniRing: View {
    let percentage: Double
    let color: Color
    var diameter: CGFloat = 36
    var lineWidth: CGFloat = 4
    /// 보조 라벨(예: "5h", "7d", "$") — 링 아래 작게 표시
    var caption: String? = nil

    private var fraction: Double { min(1, max(0, percentage / 100)) }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [color.opacity(0.6), color]),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * fraction)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)
            VStack(spacing: 0) {
                Text("\(Int(percentage.rounded()))")
                    .font(.system(size: diameter * 0.30, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                if let caption {
                    Text(caption)
                        .font(.system(size: diameter * 0.19, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// 사용량 데이터가 없을 때의 빈 미니 링
struct MiniRingEmpty: View {
    var diameter: CGFloat = 36
    var lineWidth: CGFloat = 4
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            Text("—").font(.system(size: diameter * 0.3, weight: .bold)).foregroundStyle(.secondary)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// 얇은 선형 진행 막대
struct UsageBar: View {
    let percentage: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.16))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.7), color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(1, max(0, percentage / 100))))
                    .animation(.easeInOut(duration: 0.4), value: percentage)
            }
        }
        .frame(height: height)
    }
}

/// 요금제 배지
struct PlanBadge: View {
    let plan: PlanKind

    var body: some View {
        Text(plan.label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }
}

/// 한도 1줄 카드 (아이콘 + 제목 + 리셋시간 + 막대 + %)
struct LimitCard: View {
    let icon: String
    let title: String
    let limit: LimitUsage?
    let color: Color
    var showRemaining: Bool = true
    /// true면 7일(긴 주기) 포맷/색상 규칙 적용
    var longCycle: Bool = true

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(color.opacity(0.16)).frame(width: 24, height: 24)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if let limit {
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            Text(captionText(limit, now: ctx.date))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(L.s("사용 시작 후 표시", "Shown after first use")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(limit != nil ? "\(Int((limit!.percentage).rounded()))%" : "—")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(limit != nil ? color : .secondary)
            }
            UsageBar(percentage: limit?.percentage ?? 0, color: color)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardBackground))
    }

    private func captionText(_ limit: LimitUsage, now: Date) -> String {
        let when = longCycle ? TimeFmt.resetLong(limit.resetsAt) : TimeFmt.resetShort(limit.resetsAt)
        if showRemaining, limit.resetsAt != nil {
            return "\(when) · \(TimeFmt.remaining(limit.resetsAt, now: now))"
        }
        return when
    }
}
