//
//  ClaudeMonitorShared.swift
//  ClaudeMonitorShared
//
//  앱(ClaudeMonitor)과 위젯 확장(ClaudeMonitorWidget)이 공유하는 순수 Foundation 레이어.
//  - UsageSnapshot / AccountSnapshot: 프로세스 간 공유하는 사용량 스냅샷(디스크 직렬화 포맷)
//  - SnapshotStore: App Group 컨테이너 + Application Support 두 곳에 읽고 쓴다.
//  - UsageHistoryStore: 계정별 사용률 추이(스파크라인용)를 캡 단위로 누적 저장한다.
//
//  위젯 확장은 OS 샌드박스에서 실행되므로 App Group 컨테이너만 읽을 수 있다.
//  반면 메인 앱은 샌드박스가 아니므로 App Group 이 없을 때 Application Support 로 폴백한다.
//

import Foundation

// MARK: - 공유 상수

public enum SharedConstants {
    /// App Group 식별자. 위젯과 앱이 데이터를 주고받는 컨테이너.
    /// (정상 동작하려면 호스트 앱과 위젯이 동일한 app-groups 엔타이틀먼트로 서명되어야 한다.)
    public static let appGroupId = "group.com.kimsoungryoul.ClaudeMonitor"

    /// 위젯 kind 식별자
    public static let widgetKind = "ClaudeMonitorWidget"

    /// 스냅샷 파일 이름
    public static let snapshotFileName = "snapshot.json"

    /// 폴백 저장 디렉터리 이름 (~/Library/Application Support/<dir>)
    public static let appSupportDirName = "ClaudeMonitor"
}

// MARK: - 스냅샷 모델

/// 한 계정(조직)의 사용량 스냅샷 — 위젯이 표시할 최소 정보.
public struct AccountSnapshot: Codable, Sendable, Identifiable, Equatable {
    public var id: String              // Account UUID 문자열
    public var name: String            // 표시 이름(별칭 우선)
    public var plan: String            // 요금제 라벨 ("Pro"/"Max"/…)
    public var fiveHourPct: Double?    // 5시간 사용률 0~100
    public var fiveHourResetsAt: Date?
    public var sevenDayPct: Double?    // 7일 사용률 0~100
    public var sevenDayResetsAt: Date?
    public var extraUsed: Double?      // 추가 사용액(통화 단위)
    public var extraLimit: Double?
    public var extraCurrency: String?

    public init(id: String,
                name: String,
                plan: String,
                fiveHourPct: Double? = nil,
                fiveHourResetsAt: Date? = nil,
                sevenDayPct: Double? = nil,
                sevenDayResetsAt: Date? = nil,
                extraUsed: Double? = nil,
                extraLimit: Double? = nil,
                extraCurrency: String? = nil) {
        self.id = id
        self.name = name
        self.plan = plan
        self.fiveHourPct = fiveHourPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayPct = sevenDayPct
        self.sevenDayResetsAt = sevenDayResetsAt
        self.extraUsed = extraUsed
        self.extraLimit = extraLimit
        self.extraCurrency = extraCurrency
    }

    /// 대표 사용률(5시간 우선, 없으면 7일). 위젯의 단일 게이지에 사용.
    public var primaryPct: Double? { fiveHourPct ?? sevenDayPct }
}

/// 전체 사용량 스냅샷.
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var activeAccountId: String?
    public var accounts: [AccountSnapshot]

    public init(generatedAt: Date, activeAccountId: String?, accounts: [AccountSnapshot]) {
        self.generatedAt = generatedAt
        self.activeAccountId = activeAccountId
        self.accounts = accounts
    }

    /// 활성 계정(없으면 첫 계정).
    public var activeAccount: AccountSnapshot? {
        if let id = activeAccountId, let a = accounts.first(where: { $0.id == id }) { return a }
        return accounts.first
    }

    /// 위젯 미리보기/플레이스홀더용 샘플.
    public static func placeholder(referenceDate: Date) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: referenceDate,
            activeAccountId: "placeholder",
            accounts: [
                AccountSnapshot(id: "placeholder", name: "Claude", plan: "Max",
                                fiveHourPct: 42, fiveHourResetsAt: referenceDate.addingTimeInterval(2.5 * 3600),
                                sevenDayPct: 58, sevenDayResetsAt: referenceDate.addingTimeInterval(3 * 86_400))
            ])
    }
}

// MARK: - 스냅샷 저장소

public enum SnapshotStore {
    /// App Group 컨테이너 URL (엔타이틀먼트가 없으면 nil)
    public static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupId)
    }

    /// Application Support 폴백 디렉터리 (앱 전용; 위젯 샌드박스에서는 접근 불가)
    public static var appSupportDirURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(SharedConstants.appSupportDirName, isDirectory: true)
    }

    /// 쓰기 대상 후보들(존재하는 곳 모두에 기록). App Group 우선.
    static var writeDirs: [URL] {
        var dirs: [URL] = []
        if let g = appGroupContainerURL { dirs.append(g) }
        if let s = appSupportDirURL { dirs.append(s) }
        return dirs
    }

    /// 읽기 우선순위: App Group → Application Support.
    static var readDirs: [URL] {
        var dirs: [URL] = []
        if let g = appGroupContainerURL { dirs.append(g) }
        if let s = appSupportDirURL { dirs.append(s) }
        return dirs
    }

    private static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// 스냅샷을 가능한 모든 공유 위치에 저장한다.
    @discardableResult
    public static func save(_ snapshot: UsageSnapshot) -> Bool {
        guard let data = try? encoder.encode(snapshot) else { return false }
        var wroteAny = false
        for dir in writeDirs {
            ensureDir(dir)
            let url = dir.appendingPathComponent(SharedConstants.snapshotFileName)
            if (try? data.write(to: url, options: .atomic)) != nil { wroteAny = true }
        }
        return wroteAny
    }

    /// 우선순위에 따라 스냅샷을 읽는다.
    public static func load() -> UsageSnapshot? {
        for dir in readDirs {
            let url = dir.appendingPathComponent(SharedConstants.snapshotFileName)
            if let data = try? Data(contentsOf: url),
               let snapshot = try? decoder.decode(UsageSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }

    /// 저장된 스냅샷을 모두 삭제(로그아웃/계정 제거 시).
    public static func clear() {
        for dir in writeDirs {
            let url = dir.appendingPathComponent(SharedConstants.snapshotFileName)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - 사용량 히스토리(스파크라인)

/// 한 시점의 사용률 샘플.
public struct HistoryPoint: Codable, Sendable, Equatable {
    public var t: Date
    public var fiveHour: Double?
    public var sevenDay: Double?

    public init(t: Date, fiveHour: Double?, sevenDay: Double?) {
        self.t = t
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

/// 계정별 사용률 추이를 누적 저장한다. 파일 1개/계정, 최근 N개로 캡.
public enum UsageHistoryStore {
    /// 최소 기록 간격(초): 너무 잦은 새로고침이 점을 폭증시키지 않도록.
    public static let minInterval: TimeInterval = 4 * 60
    /// 보관 최대 샘플 수.
    public static let cap = 720

    private static func fileURL(accountId: String) -> URL? {
        guard let dir = SnapshotStore.appSupportDirURL else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = accountId.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("history-\(safe).json")
    }

    public static func load(accountId: String) -> [HistoryPoint] {
        guard let url = fileURL(accountId: accountId),
              let data = try? Data(contentsOf: url),
              let pts = try? decoder.decode([HistoryPoint].self, from: data) else { return [] }
        return pts
    }

    /// 새 샘플을 추가한다. 마지막 샘플과 minInterval 이내면 덮어쓴다(잦은 새로고침 평탄화).
    public static func append(accountId: String, fiveHour: Double?, sevenDay: Double?, at date: Date) {
        guard let url = fileURL(accountId: accountId) else { return }
        var pts = load(accountId: accountId)
        let point = HistoryPoint(t: date, fiveHour: fiveHour, sevenDay: sevenDay)
        if let last = pts.last, date.timeIntervalSince(last.t) < minInterval {
            pts[pts.count - 1] = point
        } else {
            pts.append(point)
        }
        if pts.count > cap { pts.removeFirst(pts.count - cap) }
        if let data = try? encoder.encode(pts) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func clear(accountId: String) {
        guard let url = fileURL(accountId: accountId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
