//
//  AppState.swift
//  ClaudeMonitor
//
//  앱 전역 상태. 계정 목록/사용량/활성 계정/메뉴바 이미지/새로고침을 관리한다.
//

import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    /// 앱 본체가 쓰는 단일 상태. AppDelegate(실행 직후 갱신 시작)와 MenuBarExtra 씬이 같은 인스턴스를 봐야 한다.
    static let shared = AppState()

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

    // MARK: - Private

    private var timer: Timer?
    /// 진행 중인 새로고침 (재진입 방지 + 취소용)
    private var refreshTask: Task<Void, Never>?
    private enum Keys {
        static let accounts = "accounts.v1"
        static let activeId = "activeAccountId.v1"
        static let refreshMinutes = "refreshMinutes.v1"
        static let language = "language.v1"
        static let updateCheckedAt = "updateCheckedAt.v1"
        static let updateCachedTag = "updateCachedTag.v1"
        static let updateCachedURL = "updateCachedURL.v1"
    }

    /// 팝오버를 열었을 때 이 간격 안이면 새로고침을 건너뛴다(연속 오픈으로 API 를 두드리지 않게).
    private static let popoverRefreshMinInterval: TimeInterval = 60
    /// 업데이트 확인 주기 (하루 1회)
    private static let updateCheckInterval: TimeInterval = 24 * 60 * 60

    var activeAccount: Account? {
        guard let id = activeAccountId else { return accounts.first }
        return accounts.first { $0.id == id } ?? accounts.first
    }

    /// 활성 계정의 사용량 (개발 빌드의 데모 모드면 샘플)
    var activeUsage: AccountUsage? {
        #if DEBUG
        if demoMode { return DemoData.usage(for: activeAccount?.id) }
        #endif
        guard let id = activeAccount?.id else { return nil }
        return usage[id]
    }

    func usage(for account: Account) -> AccountUsage? {
        #if DEBUG
        if demoMode { return DemoData.usage(for: account.id) }
        #endif
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
    }

    // MARK: - 영속화

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: Keys.accounts),
              var list = try? JSONDecoder().decode([Account].self, from: data) else { return }
        // 과거 버전이 데모 계정을 저장해버린 경우 정리한다. 실제 조직 id 는 UUID 라 "demo-" 로 시작할 수 없다.
        let cleaned = list.filter { !$0.organizationId.hasPrefix("demo-") }
        if cleaned.count != list.count {
            list = cleaned
            if let d = try? JSONEncoder().encode(list) {
                UserDefaults.standard.set(d, forKey: Keys.accounts)
            }
        }
        for i in list.indices {
            list[i].sessionKey = Keychain.get(account: list[i].id.uuidString) ?? ""
        }
        self.accounts = list
        if let idStr = UserDefaults.standard.string(forKey: Keys.activeId),
           let id = UUID(uuidString: idStr), list.contains(where: { $0.id == id }) {
            self.activeAccountId = id
        }
    }

    private func saveAccounts() {
        // 데모 계정은 절대 디스크에 남기지 않는다. (남으면 다음 실행에서 세션 없는 유령 계정이 된다)
        let real = accounts.filter { !$0.organizationId.hasPrefix("demo-") }
        if let data = try? JSONEncoder().encode(real) {
            UserDefaults.standard.set(data, forKey: Keys.accounts)
        }
        let activeIsReal = real.contains { $0.id == activeAccountId }
        UserDefaults.standard.set(activeIsReal ? activeAccountId?.uuidString : nil, forKey: Keys.activeId)
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
        if activeAccountId == account.id { activeAccountId = accounts.first?.id }
        saveAccounts()      // 먼저 실제 계정 목록을 확정 저장하고,
        #if DEBUG
        // 개발 빌드에서만 계정이 비면 데모로 되돌린다. 릴리즈는 온보딩을 보여준다.
        if accounts.isEmpty {
            demoMode = true
            DemoData.installSampleAccounts(into: self)
            activeAccountId = accounts.first?.id
        }
        #endif
        rebuildMenuBarImage()
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
    }

    // MARK: - 새로고침

    /// 새로고침. 이미 진행 중이면 그 작업이 끝날 때까지 기다린다(중복 실행 방지).
    func refreshAll() async {
        if let running = refreshTask {
            await running.value
            return
        }
        let task = Task { @MainActor in await self.performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
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
    }

    /// 앱 실행 직후 1회: 타이머 시작 + 첫 새로고침 + 업데이트 확인.
    /// (예전에는 팝오버 onAppear 에서만 호출돼, 팝오버를 열기 전까지 메뉴바가 비어 있었다)
    func start() {
        restartTimer()
        applyCachedUpdateInfo()
        Task { await refreshAll() }
        Task { await checkForUpdate() }
    }

    /// 팝오버를 열었을 때. onAppear 는 열 때마다 발생하므로 최소 간격 안이면 아무것도 하지 않는다.
    func onPopoverAppear() {
        if timer == nil { restartTimer() }
        if let last = lastUpdated, Date().timeIntervalSince(last) < Self.popoverRefreshMinInterval { return }
        Task { await refreshAll() }
        Task { await checkForUpdate() }
    }

    /// 최신 릴리즈 확인 → 새 버전이면 updateAvailable 설정.
    /// 하루 1회만 네트워크를 쓰고, 결과는 캐시해 재실행 직후에도 배지를 보여준다.
    func checkForUpdate(force: Bool = false) async {
        let now = Date()
        if !force, let last = UserDefaults.standard.object(forKey: Keys.updateCheckedAt) as? Date,
           now.timeIntervalSince(last) < Self.updateCheckInterval {
            applyCachedUpdateInfo()
            return
        }
        let latest = await UpdateChecker.checkLatest(currentVersion: appVersion)
        UserDefaults.standard.set(now, forKey: Keys.updateCheckedAt)
        UserDefaults.standard.set(latest?.tag, forKey: Keys.updateCachedTag)
        UserDefaults.standard.set(latest?.htmlURL, forKey: Keys.updateCachedURL)
        self.updateAvailable = latest
    }

    /// 캐시된 릴리즈 정보를 현재 버전과 다시 비교해 배지를 복원한다(네트워크 없음).
    private func applyCachedUpdateInfo() {
        guard let tag = UserDefaults.standard.string(forKey: Keys.updateCachedTag),
              let url = UserDefaults.standard.string(forKey: Keys.updateCachedURL) else { return }
        let latest = UpdateChecker.parseVersion(tag)
        guard UpdateChecker.isOlder(UpdateChecker.parseVersion(appVersion), than: latest) else {
            updateAvailable = nil
            return
        }
        updateAvailable = ReleaseInfo(tag: tag, htmlURL: url, version: latest)
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
        let img = MenuBarRenderer.render(account: activeAccount, usage: usageData)
        self.menuBarImage = img
    }
}
