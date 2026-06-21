//
//  AppState.swift
//  ClaudeMonitor
//
//  앱 전역 상태. 계정 목록/사용량/활성 계정/메뉴바 이미지/새로고침을 관리한다.
//

import SwiftUI
import Combine
import ClaudeMonitorShared

/// 메뉴바에 표시할 내용 모드
enum MenuBarMode: String, CaseIterable, Identifiable, Codable {
    case both        // 5h + 7d
    case fiveHour    // 5h 만
    case sevenDay    // 7d 만
    case iconOnly    // 아이콘만

    var id: String { rawValue }
    var label: String {
        switch self {
        case .both:     return L.s("5시간 + 7일", "5h + 7d")
        case .fiveHour: return L.s("5시간만", "5h only")
        case .sevenDay: return L.s("7일만", "7d only")
        case .iconOnly: return L.s("아이콘만", "Icon only")
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - Published

    @Published var accounts: [Account] = []
    @Published var usage: [UUID: AccountUsage] = [:]
    @Published var errors: [UUID: String] = [:]
    @Published var activeAccountId: UUID?
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var menuBarImage: NSImage = NSImage()

    /// 데모 모드: 실제 계정이 없거나 사용자가 켰을 때 샘플 데이터로 UI 시연
    @Published var demoMode: Bool = false

    /// 새 버전(있으면 다운로드 제안)
    @Published var updateAvailable: ReleaseInfo?

    /// 현재 앱 버전 (Info.plist 우선, 없으면 기본값)
    let appVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"

    /// 새로고침 주기(분)
    @Published var refreshMinutes: Int {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: Keys.refreshMinutes); restartTimer() }
    }

    /// 언어 설정 (시스템/영어/한국어)
    @Published var language: AppLanguage {
        didSet {
            L.lang = language.resolved
            UserDefaults.standard.set(language.rawValue, forKey: Keys.language)
            rebuildMenuBarImage()
        }
    }

    /// 메뉴바 표시 모드
    @Published var menuBarMode: MenuBarMode {
        didSet {
            UserDefaults.standard.set(menuBarMode.rawValue, forKey: Keys.menuBarMode)
            rebuildMenuBarImage()
        }
    }

    /// 사용량 임계치 알림 사용 여부
    @Published var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            if notificationsEnabled {
                NotificationManager.shared.requestAuthorization()
                // 켜는 즉시 현재 사용량을 평가(이미 임계치를 넘은 한도가 있으면 바로 알림)
                if !demoMode {
                    NotificationManager.shared.evaluate(accounts: currentSnapshot().accounts, threshold: notifyThreshold)
                }
            } else {
                NotificationManager.shared.reset()
            }
        }
    }

    /// 알림 임계치(%)
    @Published var notifyThreshold: Int {
        didSet { UserDefaults.standard.set(notifyThreshold, forKey: Keys.notifyThreshold) }
    }

    /// 활성 계정의 사용량 추이(스파크라인용)
    @Published var activeHistory: [HistoryPoint] = []

    // MARK: - Private

    private var timer: Timer?
    private enum Keys {
        static let accounts = "accounts.v1"
        static let activeId = "activeAccountId.v1"
        static let refreshMinutes = "refreshMinutes.v1"
        static let language = "language.v1"
        static let menuBarMode = "menuBarMode.v1"
        static let notificationsEnabled = "notificationsEnabled.v1"
        static let notifyThreshold = "notifyThreshold.v1"
    }

    var activeAccount: Account? {
        guard let id = activeAccountId else { return accounts.first }
        return accounts.first { $0.id == id } ?? accounts.first
    }

    /// 활성 계정의 사용량 (데모 모드면 샘플)
    var activeUsage: AccountUsage? {
        if demoMode { return DemoData.usage(for: activeAccount?.id) }
        guard let id = activeAccount?.id else { return nil }
        return usage[id]
    }

    func usage(for account: Account) -> AccountUsage? {
        if demoMode { return DemoData.usage(for: account.id) }
        return usage[account.id]
    }

    // MARK: - Init

    init(demo: Bool = false) {
        let stored = UserDefaults.standard.integer(forKey: Keys.refreshMinutes)
        self.refreshMinutes = stored == 0 ? 5 : stored
        let langRaw = UserDefaults.standard.string(forKey: Keys.language)
        let lang = langRaw.flatMap { AppLanguage(rawValue: $0) } ?? .system
        self.language = lang
        L.lang = lang.resolved
        let modeRaw = UserDefaults.standard.string(forKey: Keys.menuBarMode)
        self.menuBarMode = modeRaw.flatMap { MenuBarMode(rawValue: $0) } ?? .both
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: Keys.notificationsEnabled)
        let thr = UserDefaults.standard.integer(forKey: Keys.notifyThreshold)
        self.notifyThreshold = thr == 0 ? 80 : thr
        loadAccounts()
        // 데모 모드는 개발 빌드 전용. 릴리즈에서는 계정이 없으면 온보딩을 보여준다.
        #if DEBUG
        if demo || accounts.isEmpty {
            self.demoMode = true
            if accounts.isEmpty { DemoData.installSampleAccounts(into: self) }
        }
        #else
        _ = demo
        #endif
        if activeAccountId == nil { activeAccountId = accounts.first?.id }
        rebuildMenuBarImage()
        loadActiveHistory()
        publishSnapshot()
    }

    // MARK: - 영속화

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: Keys.accounts),
              var list = try? JSONDecoder().decode([Account].self, from: data) else { return }
        for i in list.indices {
            list[i].sessionKey = Keychain.get(account: list[i].id.uuidString) ?? ""
        }
        self.accounts = list
        if let idStr = UserDefaults.standard.string(forKey: Keys.activeId) {
            self.activeAccountId = UUID(uuidString: idStr)
        }
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Keys.accounts)
        }
        UserDefaults.standard.set(activeAccountId?.uuidString, forKey: Keys.activeId)
    }

    // MARK: - 계정 관리

    /// 세션 키로 조직을 조회해 계정으로 추가한다. (이미 있는 조직은 sessionKey 갱신)
    func addAccounts(sessionKey: String) async -> Result<Int, ClaudeAPIError> {
        do {
            let orgs = try await ClaudeAPI.shared.fetchOrganizations(sessionKey: sessionKey)
            // 데모 모드였다면 실제 계정이 들어오기 전에 샘플 계정을 모두 비운다 (중복/오인 방지)
            if demoMode {
                demoMode = false
                accounts.removeAll()
                usage.removeAll()
                errors.removeAll()
                activeAccountId = nil
            }
            var added = 0
            for org in orgs {
                if let idx = accounts.firstIndex(where: { $0.organizationId == org.uuid }) {
                    accounts[idx].sessionKey = sessionKey
                    accounts[idx].organizationName = org.name
                    accounts[idx].planRaw = org.plan.rawValue
                    Keychain.set(sessionKey, account: accounts[idx].id.uuidString)
                } else {
                    let acc = Account(organizationId: org.uuid,
                                      organizationName: org.name,
                                      plan: org.plan,
                                      sessionKey: sessionKey)
                    Keychain.set(sessionKey, account: acc.id.uuidString)
                    accounts.append(acc)
                    added += 1
                }
            }
            if activeAccountId == nil || !accounts.contains(where: { $0.id == activeAccountId }) {
                activeAccountId = accounts.first?.id
            }
            saveAccounts()
            await refreshAll()
            return .success(added)
        } catch let e as ClaudeAPIError {
            return .failure(e)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    func removeAccount(_ account: Account) {
        Keychain.delete(account: account.id.uuidString)
        accounts.removeAll { $0.id == account.id }
        usage[account.id] = nil
        errors[account.id] = nil
        NotificationManager.shared.reset(accountId: account.id.uuidString)
        UsageHistoryStore.clear(accountId: account.id.uuidString)
        if activeAccountId == account.id { activeAccountId = accounts.first?.id }
        if accounts.isEmpty {
            #if DEBUG
            demoMode = true
            DemoData.installSampleAccounts(into: self)
            activeAccountId = accounts.first?.id
            #else
            SnapshotStore.clear()
            #endif
        }
        saveAccounts()
        rebuildMenuBarImage()
        loadActiveHistory()
        publishSnapshot()
    }

    func setAlias(_ alias: String?, for account: Account) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].alias = alias
        saveAccounts()
        rebuildMenuBarImage()
    }

    func setActive(_ account: Account) {
        activeAccountId = account.id
        saveAccounts()
        rebuildMenuBarImage()
        loadActiveHistory()
        // 활성 계정 전환은 로컬 변경이므로 스냅샷만 갱신하고 위젯 리로드는 생략한다
        // (WidgetCenter.reloadTimelines 는 OS 가 rate-limit 하므로 잦은 호출을 피한다).
        publishSnapshot(reloadWidget: false)
    }

    // MARK: - 새로고침

    func refreshAll() async {
        guard !demoMode else { rebuildMenuBarImage(); return }
        guard !accounts.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: (UUID, Result<AccountUsage, ClaudeAPIError>).self) { group in
            for account in accounts {
                let id = account.id
                let org = account.organizationId
                let key = account.sessionKey
                group.addTask {
                    guard !key.isEmpty else { return (id, .failure(.unauthorized)) }
                    do {
                        let u = try await ClaudeAPI.shared.fetchUsage(organizationId: org, sessionKey: key)
                        return (id, .success(u))
                    } catch let e as ClaudeAPIError {
                        return (id, .failure(e))
                    } catch {
                        return (id, .failure(.network(error.localizedDescription)))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let u):
                    usage[id] = u
                    errors[id] = nil
                case .failure(let e):
                    errors[id] = e.errorDescription
                }
            }
        }
        lastUpdated = Date()
        rebuildMenuBarImage()
        publishSnapshot()
        loadActiveHistory()
    }

    func startTimer() {
        restartTimer()
        if notificationsEnabled { NotificationManager.shared.requestAuthorization() }
        Task { await refreshAll() }
        Task { await checkForUpdate() }
    }

    /// 최신 릴리즈 확인 → 새 버전이면 updateAvailable 설정
    func checkForUpdate() async {
        let latest = await UpdateChecker.checkLatest(currentVersion: appVersion)
        self.updateAvailable = latest
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, refreshMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    // MARK: - 메뉴바 이미지

    /// 활성 계정의 5h/7d 사용률을 컬러 텍스트 이미지로 렌더링해 메뉴바에 표시
    func rebuildMenuBarImage() {
        let usageData = activeUsage
        let img = MenuBarRenderer.render(account: activeAccount, usage: usageData, mode: menuBarMode)
        self.menuBarImage = img
    }

    // MARK: - 위젯/히스토리/알림 발행

    /// 현재 상태를 위젯이 읽을 스냅샷으로 만든다(데모 포함, 위젯에서 시연 가능).
    private func currentSnapshot() -> UsageSnapshot {
        let accs: [AccountSnapshot] = accounts.map { acc in
            let u = usage(for: acc)
            let extra = u?.extra
            return AccountSnapshot(
                id: acc.id.uuidString,
                name: acc.displayName,
                plan: acc.plan.label,
                fiveHourPct: u?.fiveHour?.percentage,
                fiveHourResetsAt: u?.fiveHour?.resetsAt,
                sevenDayPct: u?.sevenDay?.percentage,
                sevenDayResetsAt: u?.sevenDay?.resetsAt,
                extraUsed: (extra?.enabled == true) ? extra?.used : nil,
                extraLimit: (extra?.enabled == true) ? extra?.limit : nil,
                extraCurrency: (extra?.enabled == true) ? extra?.currencyCode : nil)
        }
        return UsageSnapshot(generatedAt: Date(),
                             activeAccountId: activeAccount?.id.uuidString,
                             accounts: accs)
    }

    /// 스냅샷 저장 → 위젯 리로드, 그리고 (실데이터일 때) 히스토리 적재 + 임계치 알림 평가.
    /// - Parameter reloadWidget: 위젯 타임라인을 리로드할지(로컬 변경만일 때는 false 로 생략).
    func publishSnapshot(reloadWidget: Bool = true) {
        let snapshot = currentSnapshot()
        SnapshotStore.save(snapshot)
        if reloadWidget { WidgetBridge.reload() }

        // 히스토리/알림은 실제 데이터에 대해서만 (데모 데이터로 오염시키지 않음)
        guard !demoMode else { return }
        let now = Date()
        for acc in accounts {
            guard let u = usage[acc.id] else { continue }
            UsageHistoryStore.append(accountId: acc.id.uuidString,
                                     fiveHour: u.fiveHour?.percentage,
                                     sevenDay: u.sevenDay?.percentage,
                                     at: now)
        }
        if notificationsEnabled {
            NotificationManager.shared.evaluate(accounts: snapshot.accounts, threshold: notifyThreshold)
        }
    }

    /// 활성 계정의 히스토리를 디스크에서 읽어 @Published 로 노출(스파크라인).
    func loadActiveHistory() {
        guard !demoMode, let id = activeAccount?.id else { activeHistory = []; return }
        activeHistory = UsageHistoryStore.load(accountId: id.uuidString)
    }
}
