//
//  UsageNotifier.swift
//  ClaudeMonitor
//
//  사용량이 임계값을 넘으면 알림 센터로 알린다.
//  한 리셋 주기 안에서는 한도별로 한 번만 보낸다(같은 경고가 5분마다 반복되지 않게).
//

import Foundation
import UserNotifications

@MainActor
enum UsageNotifier {
    /// 이미 알린 (계정, 한도, 리셋시각) 조합 → 보낸 시각. 오래된 항목은 정리한다.
    private static let sentKey = "notifiedLimits.v1"
    private static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// 알림 권한 요청. 번들이 아닌 개발용 raw 바이너리에서는 알림을 쓸 수 없으므로 false.
    static func requestAuthorization() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// 새 사용량 스냅샷을 보고 임계값을 넘은 한도를 알린다.
    /// - Parameter threshold: 0~100. 이 값 이상이면 알린다.
    static func evaluate(accounts: [Account], usage: [UUID: AccountUsage], threshold: Double) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        var sent = loadSent()
        let now = Date()

        for account in accounts {
            guard let u = usage[account.id] else { continue }
            var limits: [(tag: String, title: String, limit: LimitUsage)] = []
            if let five = u.fiveHour { limits.append(("5h", L.s("5시간 한도", "5-hour limit"), five)) }
            if let seven = u.sevenDay { limits.append(("7d", L.s("7일 한도", "7-day limit"), seven)) }
            for model in u.models {
                limits.append((model.shortTag, L.s("\(model.name) 주간 한도", "\(model.name) weekly limit"), model.usage))
            }

            for entry in limits where entry.limit.percentage >= threshold {
                // 리셋 시각이 키에 들어가므로, 주기가 바뀌면 자동으로 다시 알릴 수 있다.
                let cycle = entry.limit.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
                let key = "\(account.id.uuidString)|\(entry.tag)|\(cycle)"
                guard sent[key] == nil else { continue }
                sent[key] = now
                send(account: account, title: entry.title, limit: entry.limit)
            }
        }

        saveSent(sent.filter { now.timeIntervalSince($0.value) < retention })
    }

    private static func send(account: Account, title: String, limit: LimitUsage) {
        let content = UNMutableNotificationContent()
        content.title = L.s("Claude 사용량 경고", "Claude usage warning")
        let percent = Int(limit.percentage.rounded())
        if let reset = limit.resetsAt {
            content.body = L.s("\(account.displayName) · \(title) \(percent)% (\(TimeFmt.resetShort(reset)) 리셋)",
                               "\(account.displayName) · \(title) at \(percent)% (resets \(TimeFmt.resetShort(reset)))")
        } else {
            content.body = "\(account.displayName) · \(title) \(percent)%"
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 보낸 기록

    private static func loadSent() -> [String: Date] {
        UserDefaults.standard.dictionary(forKey: sentKey) as? [String: Date] ?? [:]
    }

    private static func saveSent(_ value: [String: Date]) {
        UserDefaults.standard.set(value, forKey: sentKey)
    }
}
