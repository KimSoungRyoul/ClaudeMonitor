//
//  DemoData.swift
//  ClaudeMonitor
//
//  계정이 없을 때 UI 를 시연하기 위한 샘플 데이터.
//  스크린샷의 샘플 A / 샘플 B / 샘플 C / 샘플 D 구성을 본떴다.
//

import Foundation

enum DemoData {
    // 안정적인 데모 계정 ID (재실행 시에도 동일하게 매핑되도록 고정)
    static let ids: [UUID] = [
        UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
        UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!,
        UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!
    ]

    @MainActor
    static func installSampleAccounts(into state: AppState) {
        // 실제 계정으로 오인되지 않도록 명백한 데모 이름 사용
        let accs = [
            Account(id: ids[0], organizationId: "demo-a", organizationName: "Demo · A", plan: .team),
            Account(id: ids[1], organizationId: "demo-b", organizationName: "Demo · B", plan: .max),
            Account(id: ids[2], organizationId: "demo-c", organizationName: "Demo · C", plan: .max),
            Account(id: ids[3], organizationId: "demo-d", organizationName: "Demo · Enterprise", plan: .enterprise)
        ]
        state.accounts = accs
    }

    static func usage(for id: UUID?) -> AccountUsage {
        let now = Date()
        func at(_ hours: Double) -> Date {
            let d = now.addingTimeInterval(hours * 3600)
            let cal = Calendar.current
            var c = cal.dateComponents([.year, .month, .day, .hour], from: d)
            c.minute = 0; c.second = 0
            return cal.date(from: c) ?? d
        }
        switch id {
        case ids[0]: // 샘플 A
            return AccountUsage(
                fiveHour: LimitUsage(percentage: 42, resetsAt: at(2.5)),
                sevenDay: LimitUsage(percentage: 58, resetsAt: at(24 * 3 + 5)),
                opus: LimitUsage(percentage: 30, resetsAt: at(24 * 4)),
                sonnet: nil, extra: nil)
        case ids[1]: // 샘플 B (7일 1.5일 남음 → 노랑 데모)
            return AccountUsage(
                fiveHour: LimitUsage(percentage: 8, resetsAt: at(3.8)),
                sevenDay: LimitUsage(percentage: 19, resetsAt: at(36)),
                opus: nil, sonnet: nil, extra: nil)
        case ids[2]: // 샘플 C (5시간 곧/7일 18시간 남음 → 빨강 데모)
            return AccountUsage(
                fiveHour: LimitUsage(percentage: 9, resetsAt: at(1.2)),
                sevenDay: LimitUsage(percentage: 31, resetsAt: at(18)),
                opus: nil, sonnet: nil, extra: nil)
        case ids[3]: // 샘플 D (Enterprise + Extra Usage)
            return AccountUsage(
                fiveHour: nil,
                sevenDay: LimitUsage(percentage: 64, resetsAt: at(24 * 2 + 3)),
                opus: nil, sonnet: nil,
                extra: ExtraUsage(enabled: true, used: 75.1, limit: 200, currencyCode: "USD"))
        default:
            return AccountUsage(
                fiveHour: LimitUsage(percentage: 25, resetsAt: at(2)),
                sevenDay: LimitUsage(percentage: 40, resetsAt: at(24 * 4)),
                opus: nil, sonnet: nil, extra: nil)
        }
    }
}
