//
//  Sparkline.swift
//  ClaudeMonitor
//
//  활성 계정의 최근 5시간/7일 사용률 추이를 작은 라인 차트로 보여준다.
//  데이터는 UsageHistoryStore(Application Support)에서 적재된 HistoryPoint 배열.
//

import SwiftUI
import ClaudeMonitorShared

struct SparklineView: View {
    let points: [HistoryPoint]

    private var fivePts: [Double] { points.compactMap { $0.fiveHour } }
    private var sevenPts: [Double] { points.compactMap { $0.sevenDay } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(L.s("사용량 추이", "Usage trend"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                legend(color: Theme.fiveHourColor(0), label: "5h")
                legend(color: Theme.sevenDayColor(0), label: "7d")
            }
            ZStack {
                // 0~100 기준선
                GeometryReader { geo in
                    Path { p in
                        let midY = geo.size.height * 0.5
                        p.move(to: CGPoint(x: 0, y: midY))
                        p.addLine(to: CGPoint(x: geo.size.width, y: midY))
                    }
                    .stroke(Color.secondary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                sparkPath(fivePts, color: Theme.fiveHourColor(fivePts.last ?? 0))
                sparkPath(sevenPts, color: Theme.sevenDayColor(sevenPts.last ?? 0))
            }
            .frame(height: 34)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardBackground))
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    /// 0~100 사용률 배열을 정규화해 라인으로 그린다.
    private func sparkPath(_ values: [Double], color: Color) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                if values.count >= 2 {
                    let path = linePath(values, width: w, height: h)
                    // 채움(아래쪽 그라데이션)
                    fillPath(values, width: w, height: h)
                        .fill(LinearGradient(colors: [color.opacity(0.25), color.opacity(0.0)],
                                             startPoint: .top, endPoint: .bottom))
                    path.stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func point(_ value: Double, index: Int, count: Int, width: CGFloat, height: CGFloat) -> CGPoint {
        let x = count <= 1 ? width : width * CGFloat(index) / CGFloat(count - 1)
        let y = height * (1 - CGFloat(min(100, max(0, value)) / 100))
        return CGPoint(x: x, y: y)
    }

    private func linePath(_ values: [Double], width: CGFloat, height: CGFloat) -> Path {
        Path { p in
            for (i, v) in values.enumerated() {
                let pt = point(v, index: i, count: values.count, width: width, height: height)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func fillPath(_ values: [Double], width: CGFloat, height: CGFloat) -> Path {
        Path { p in
            for (i, v) in values.enumerated() {
                let pt = point(v, index: i, count: values.count, width: width, height: height)
                if i == 0 { p.move(to: CGPoint(x: pt.x, y: height)); p.addLine(to: pt) }
                else { p.addLine(to: pt) }
            }
            p.addLine(to: CGPoint(x: width, y: height))
            p.closeSubpath()
        }
    }
}
