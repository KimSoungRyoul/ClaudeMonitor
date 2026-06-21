//
//  NotificationManager.swift
//  ClaudeMonitor
//
//  사용량 임계치 알림. 5시간/7일 한도가 설정한 임계치를 "처음 넘는" 순간 한 번만 알림을 보낸다.
//  (매 새로고침마다 반복 알림하지 않도록 한도별 알림 상태를 추적한다.)
//
//  주의: UNUserNotificationCenter.current() 는 번들 ID 가 없으면 예외로 크래시하므로,
//  정식 .app 번들로 실행 중일 때만 동작한다(raw 바이너리/프리뷰에서는 no-op).
//

import Foundation
import UserNotifications
import ClaudeMonitorShared

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    /// 정식 번들(.app)로 실행 중일 때만 알림을 사용할 수 있다.
    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// 이미 알림을 보낸 한도 키 집합("<id>|5h", "<id>|7d"). 임계치 아래로 내려가면 해제.
    private var alerted: Set<String> = []

    private init() {}

    /// 알림 권한 요청(앱 시작 시 등). 권한 프롬프트는 OS 가 1회만 띄운다.
    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 설정에서 알림을 켤 때 호출. 권한이 "승인된 뒤"에만 즉시 평가한다.
    /// (권한이 아직 .notDetermined 인데 바로 evaluate 하면 알림이 드롭되면서도
    ///  alerted 에 기록되어 다음 주기에도 재발화하지 않는 문제를 막는다.)
    func enable(evaluateAccounts accounts: [AccountSnapshot], threshold: Int) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted, !accounts.isEmpty else { return }
            Task { @MainActor in self?.evaluate(accounts: accounts, threshold: threshold) }
        }
    }

    /// 계정 스냅샷들을 평가해 임계치를 새로 넘은 한도에 알림을 보낸다.
    /// - Parameters:
    ///   - accounts: 현재 계정 스냅샷
    ///   - threshold: 경고 임계치(%) — 이 값 이상이면 알림
    func evaluate(accounts: [AccountSnapshot], threshold: Int) {
        guard isAvailable else { return }
        let limit = Double(threshold)
        for acc in accounts {
            check(account: acc, kind: .fiveHour, pct: acc.fiveHourPct, threshold: limit)
            check(account: acc, kind: .sevenDay, pct: acc.sevenDayPct, threshold: limit)
        }
    }

    /// 계정 제거/로그아웃 시 추적 상태 정리.
    func reset(accountId: String? = nil) {
        if let accountId {
            alerted = alerted.filter { !$0.hasPrefix(accountId + "|") }
        } else {
            alerted.removeAll()
        }
    }

    // MARK: - 내부

    private enum Kind {
        case fiveHour, sevenDay
        var tag: String { self == .fiveHour ? "5h" : "7d" }
        var title: String {
            self == .fiveHour ? L.s("5시간 한도 경고", "5-hour limit alert")
                              : L.s("7일 한도 경고", "7-day limit alert")
        }
    }

    private func check(account: AccountSnapshot, kind: Kind, pct: Double?, threshold: Double) {
        guard let pct else { return }
        let key = "\(account.id)|\(kind.tag)"
        if pct >= threshold {
            guard !alerted.contains(key) else { return }   // 이미 알림 보냄 → 중복 방지
            alerted.insert(key)
            send(title: kind.title,
                 body: L.s("\(account.name) — \(kind.tag) 사용량 \(Int(pct.rounded()))% 도달",
                           "\(account.name) — \(kind.tag) usage reached \(Int(pct.rounded()))%"),
                 id: key)
        } else {
            alerted.remove(key)   // 임계치 아래로 내려감 → 다음 주기에 재알림 허용
        }
    }

    private func send(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(id)-\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
