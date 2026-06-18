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
    private enum Keys {
        static let accounts = "accounts.v1"
        static let activeId = "activeAccountId.v1"
        static let refreshMinutes = "refreshMinutes.v1"
        static let language = "language.v1"
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
        if activeAccountId == account.id { activeAccountId = accounts.first?.id }
        if accounts.isEmpty {
            demoMode = true
            DemoData.installSampleAccounts(into: self)
            activeAccountId = accounts.first?.id
        }
        saveAccounts()
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
    }

    func startTimer() {
        restartTimer()
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
        let img = MenuBarRenderer.render(account: activeAccount, usage: usageData)
        self.menuBarImage = img
    }
}
