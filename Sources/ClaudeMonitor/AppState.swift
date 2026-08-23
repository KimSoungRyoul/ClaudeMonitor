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

    /// 저장소 문제(키체인 쓰기 실패, 설정 손상 등) — 조용히 삼키지 않고 UI 에 띄운다.
    @Published var storageWarning: String?

    /// 현재 앱 버전 (Info.plist 우선, 없으면 기본값)
    let appVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"

    /// 새로고침 주기(분)
    @Published var refreshMinutes: Int {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: Keys.refreshMinutes); restartTimer() }
    }

    /// 사용량 임계값 알림 사용 여부
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    /// 알림을 보낼 사용률(%) 임계값
    @Published var notificationThreshold: Int {
        didSet { UserDefaults.standard.set(notificationThreshold, forKey: Keys.notificationThreshold) }
    }

    /// 모델별 주간 한도(Fable 등) 표시 여부. 끄면 히어로 링·계정 행·알림에서 모두 빠진다.
    /// (같은 usage 응답에 딸려오는 값이라 껐다 켜도 재조회가 필요 없다 — 캐시에는 그대로 남긴다)
    @Published var showModelLimits: Bool {
        didSet {
            UserDefaults.standard.set(showModelLimits, forKey: Keys.showModelLimits)
            rebuildMenuBarImage()
        }
    }

    /// 세션이 만료된 계정 (행에서 바로 다시 로그인할 수 있게 표시)
    @Published var expiredAccounts: Set<UUID> = []

    /// 만료된 계정을 Chrome 로그인 세션에서 자동으로 되살린다 (기본 off — 켤 때 Keychain 접근을 한 번 승인해야 한다).
    @Published var chromeAutoSync: Bool {
        didSet { UserDefaults.standard.set(chromeAutoSync, forKey: Keys.chromeAutoSync) }
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
    /// 새로고침 회차 번호. 끝난 회차와 새로 시작된 회차를 구분한다(Task 는 값 타입이라 동일성 비교가 안 된다).
    private var refreshTaskId = 0
    /// 연속 실패 횟수 (백오프 계산용)
    private var consecutiveFailures = 0
    /// 한 계정도 못 가져온 회차가 연속 몇 번인지 (브라우저 컨텍스트 재생성 판단용)
    private var consecutiveEmptyRefreshes = 0
    /// 백오프 중이면 이 시각 전에는 자동 새로고침을 건너뛴다. (수동 새로고침은 무시하고 바로 시도)
    private var nextAutoRefreshAllowedAt: Date?
    /// 시스템 테마 변경 관찰자
    private var appearanceObserver: NSObjectProtocol?

    private enum Keys {
        static let accounts = "accounts.v1"
        static let accountsCorrupt = "accounts.v1.corrupt"
        static let activeId = "activeAccountId.v1"
        static let refreshMinutes = "refreshMinutes.v1"
        static let language = "language.v1"
        static let updateCheckedAt = "updateCheckedAt.v1"
        static let updateCachedTag = "updateCachedTag.v1"
        static let updateCachedURL = "updateCachedURL.v1"
        static let usageCache = "usageCache.v1"
        static let usageCachedAt = "usageCachedAt.v1"
        static let notificationsEnabled = "notificationsEnabled.v1"
        static let notificationThreshold = "notificationThreshold.v1"
        static let showModelLimits = "showModelLimits.v1"
        static let chromeAutoSync = "chromeAutoSync.v1"
    }

    /// 팝오버를 열었을 때 이 간격 안이면 새로고침을 건너뛴다(연속 오픈으로 API 를 두드리지 않게).
    private static let popoverRefreshMinInterval: TimeInterval = 60
    /// 업데이트 확인 주기 (하루 1회)
    private static let updateCheckInterval: TimeInterval = 24 * 60 * 60
    /// 백오프 상한 (연속 실패가 이어져도 이보다 오래 쉬지는 않는다)
    private static let maxBackoff: TimeInterval = 30 * 60

    /// Chrome 자동 복구 재진입 가드
    private var isRestoringFromChrome = false
    /// 마지막 Chrome 자동 복구 시각 (쿨다운 — 만료가 안 풀려도 매 새로고침마다 Chrome 을 뒤지지 않게)
    private var lastChromeRestoreAt: Date?
    /// Chrome 자동 복구 최소 간격
    private static let chromeRestoreCooldown: TimeInterval = 10 * 60

    var activeAccount: Account? {
        guard let id = activeAccountId else { return accounts.first }
        return accounts.first { $0.id == id } ?? accounts.first
    }

    /// 활성 계정의 사용량 (개발 빌드의 데모 모드면 샘플)
    var activeUsage: AccountUsage? {
        #if DEBUG
        if demoMode { return displayed(DemoData.usage(for: activeAccount?.id)) }
        #endif
        guard let id = activeAccount?.id else { return nil }
        return displayed(usage[id])
    }

    func usage(for account: Account) -> AccountUsage? {
        #if DEBUG
        if demoMode { return displayed(DemoData.usage(for: account.id)) }
        #endif
        return displayed(usage[account.id])
    }

    /// 표시 옵션을 반영한 사용량. UI 가 읽는 경로(히어로 링/계정 행/메뉴바)는 모두 여기를 거친다.
    private func displayed(_ u: AccountUsage?) -> AccountUsage? {
        Self.applyDisplayOptions(u, showModelLimits: showModelLimits)
    }

    /// 표시 옵션 적용(순수 함수 — 테스트에서 직접 검증한다).
    /// `showModelLimits == false` 면 모델별 주간 한도(Fable 등)를 빼고 돌려준다.
    nonisolated static func applyDisplayOptions(_ usage: AccountUsage?, showModelLimits: Bool) -> AccountUsage? {
        guard let usage else { return nil }
        guard !showModelLimits, !usage.models.isEmpty else { return usage }
        return AccountUsage(fiveHour: usage.fiveHour, sevenDay: usage.sevenDay,
                            models: [], extra: usage.extra)
    }

    // MARK: - Init

    init(demo: Bool = false) {
        let stored = UserDefaults.standard.integer(forKey: Keys.refreshMinutes)
        self.refreshMinutes = stored == 0 ? 5 : stored
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: Keys.notificationsEnabled)
        let threshold = UserDefaults.standard.integer(forKey: Keys.notificationThreshold)
        self.notificationThreshold = threshold == 0 ? 90 : threshold
        self.chromeAutoSync = UserDefaults.standard.bool(forKey: Keys.chromeAutoSync)
        // 기본값은 표시(기존 동작 유지). bool(forKey:) 는 키가 없을 때도 false 라 object 로 구분한다.
        self.showModelLimits = (UserDefaults.standard.object(forKey: Keys.showModelLimits) as? Bool) ?? true
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
        loadUsageCache()        // 첫 조회가 끝나기 전에도 지난 값을 보여준다
        rebuildMenuBarImage()
    }

    /// 마지막 갱신이 너무 오래됐는가 (조회가 계속 실패하는 동안 낡은 값을 최신처럼 보여주지 않기 위해).
    var isStale: Bool {
        guard let lastUpdated else { return !usage.isEmpty }
        return Date().timeIntervalSince(lastUpdated) > max(TimeInterval(refreshMinutes * 60) * 2, 15 * 60)
    }

    // MARK: - 영속화

    /// 디스크에 저장해도 되는 계정만. 데모 계정은 절대 남기지 않는다.
    /// (남으면 다음 실행에서 세션 없는 유령 계정이 되고, 릴리즈에선 지울 방법이 없어진다)
    nonisolated static func persistable(_ accounts: [Account]) -> [Account] {
        accounts.filter { !$0.organizationId.hasPrefix("demo-") }
    }

    /// 저장분을 불러올 때의 정리. 실제 조직 id 는 UUID 라 "demo-" 로 시작할 수 없으므로,
    /// 그런 항목은 과거 버전이 남긴 데모 계정이다.
    nonisolated static func sanitizeLoaded(_ accounts: [Account]) -> [Account] {
        persistable(accounts)
    }

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: Keys.accounts) else { return }
        guard var list = try? JSONDecoder().decode([Account].self, from: data) else {
            // 손상된 설정을 조용히 덮어쓰면 계정이 통째로 사라진다. 원본은 남기고 사용자에게 알린다.
            UserDefaults.standard.set(data, forKey: Keys.accountsCorrupt)
            storageWarning = L.s("저장된 계정 정보를 읽지 못했습니다. 다시 로그인해 주세요.",
                                 "Could not read the saved accounts. Please log in again.")
            return
        }
        let cleaned = Self.sanitizeLoaded(list)
        if cleaned.count != list.count {
            list = cleaned
            if let d = try? JSONEncoder().encode(list) {
                UserDefaults.standard.set(d, forKey: Keys.accounts)
            }
        }
        // 세션은 항목 1개에 모여 있으므로 한 번만 읽는다 (계정마다 읽으면 접근 허용도 계정 수만큼 뜬다).
        let sessions = Keychain.loadAll(accountIds: list.map { $0.id.uuidString })
        for i in list.indices {
            list[i].sessionKey = sessions[list[i].id.uuidString] ?? ""
        }
        self.accounts = list
        if let idStr = UserDefaults.standard.string(forKey: Keys.activeId),
           let id = UUID(uuidString: idStr), list.contains(where: { $0.id == id }) {
            self.activeAccountId = id
        }
    }

    private func saveAccounts() {
        let real = Self.persistable(accounts)
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
            // 한 세션 키에 조직이 여러 개 붙으므로, 조직마다 쓰지 않고 모아서 한 번에 저장한다.
            var pendingSessions: [String: String] = [:]
            // API 전용 조직(console.anthropic.com)은 claude.ai 사용량이 없다 → 계정으로 담지 않는다.
            for org in orgs where org.reportsUsage {
                if let idx = accounts.firstIndex(where: { $0.organizationId == org.uuid }) {
                    accounts[idx].sessionKey = sessionKey
                    accounts[idx].organizationName = org.name
                    accounts[idx].planRaw = org.plan.rawValue
                    pendingSessions[accounts[idx].id.uuidString] = sessionKey
                } else {
                    let acc = Account(organizationId: org.uuid,
                                      organizationName: org.name,
                                      plan: org.plan,
                                      sessionKey: sessionKey)
                    pendingSessions[acc.id.uuidString] = sessionKey
                    accounts.append(acc)
                    added += 1
                }
            }
            let keychainFailed = !Keychain.setMany(pendingSessions)
            if activeAccountId == nil || !accounts.contains(where: { $0.id == activeAccountId }) {
                activeAccountId = accounts.first?.id
            }
            // 키체인 쓰기 실패를 삼키면 다음 실행에서 세션이 사라진 채로 뜬다.
            storageWarning = keychainFailed
                ? L.s("키체인에 세션을 저장하지 못했습니다. 앱을 다시 켜면 로그인이 필요합니다.",
                      "Could not save the session to the Keychain. You will need to log in again after a restart.")
                : nil
            saveAccounts()
            // 방금 세션 키를 갈아끼웠다 — 진행 중이던 회차에 묻어가면 새 키가 반영되지 않는다.
            await refreshAll(force: true)
            return .success(added)
        } catch let e as ClaudeAPIError {
            return .failure(e)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    // MARK: - Chrome 세션 가져오기

    /// Chrome 세션 가져오기 결과.
    /// - `keys`: 브라우저에서 꺼낸 sessionKey 개수
    /// - `usable`: 그중 claude.ai 가 실제로 받아준(조직을 돌려준) 개수
    /// - `added`: 새로 만들어진 계정 수 (이미 있던 조직은 키만 갱신되므로 0 일 수 있다)
    /// - `failure`: 하나도 못 쓴 경우의 이유
    struct ChromeImport {
        let keys: Int
        let usable: Int
        let added: Int
        let sources: [String]
        let failure: ClaudeAPIError?
    }

    /// 로그인된 Chrome(및 Chromium 계열)에서 claude.ai 세션을 읽어 계정으로 추가/갱신한다(수동).
    /// Keychain 접근이 동기+프롬프트라 백그라운드에서 읽고, 계정 반영은 메인 액터에서 한다.
    func importFromChrome() async -> Result<ChromeImport, ChromeCookies.ImportError> {
        let extracted: ChromeCookies.Result
        do {
            extracted = try await Self.readChromeSessions()
        } catch let e as ChromeCookies.ImportError {
            return .failure(e)
        } catch {
            return .failure(.decryptFailed)
        }
        // 키마다 결과가 다르다. 하나도 못 썼는데 "가져왔습니다"라고 하면 사용자는 고쳐진 줄 알고
        // 빨간 줄만 계속 보게 된다 — 실제로 쓸 수 있었던 개수와 실패 이유를 그대로 올려보낸다.
        var totalAdded = 0
        var usable = 0
        var firstFailure: ClaudeAPIError?
        for key in extracted.sessionKeys {
            switch await addAccounts(sessionKey: key) {
            case .success(let n):
                usable += 1
                totalAdded += n
            case .failure(let e):
                if firstFailure == nil { firstFailure = e }
            }
        }
        return .success(ChromeImport(keys: extracted.sessionKeys.count,
                                     usable: usable,
                                     added: totalAdded,
                                     sources: extracted.sources,
                                     failure: usable == 0 ? firstFailure : nil))
    }

    /// 만료된 계정이 남아 있고 자동 동기화가 켜져 있으면, Chrome 세션에서 조용히 키를 교체해 되살린다.
    /// (수동 가져오기와 달리 새 계정을 추가하지는 않는다 — 기존 계정의 sessionKey 만 갱신한다.)
    private func maybeAutoRestoreFromChrome() async {
        guard chromeAutoSync, !expiredAccounts.isEmpty, !isRestoringFromChrome else { return }
        if let last = lastChromeRestoreAt, Date().timeIntervalSince(last) < Self.chromeRestoreCooldown { return }
        isRestoringFromChrome = true
        lastChromeRestoreAt = Date()
        defer { isRestoringFromChrome = false }

        guard let extracted = try? await Self.readChromeSessions() else { return }
        // 만료된 계정의 조직 id → 계정. Chrome 에서 얻은 각 키가 이 조직을 포함하면 키를 교체한다.
        let expired = accounts.filter { expiredAccounts.contains($0.id) }
        guard !expired.isEmpty else { return }

        var pending: [String: String] = [:]
        for key in extracted.sessionKeys {
            guard let orgs = try? await ClaudeAPI.shared.fetchOrganizations(sessionKey: key) else { continue }
            let orgIds = Set(orgs.filter(\.reportsUsage).map(\.uuid))
            for account in expired where orgIds.contains(account.organizationId) {
                if let idx = accounts.firstIndex(where: { $0.id == account.id }),
                   accounts[idx].sessionKey != key {
                    accounts[idx].sessionKey = key
                    pending[account.id.uuidString] = key
                }
            }
        }
        guard !pending.isEmpty else { return }
        _ = Keychain.setMany(pending)
        saveAccounts()
        // 키를 갈아끼웠으니 한 번 더 새로고침 (재진입 가드로 여기서 다시 복구가 돌지는 않는다).
        await refreshAll(force: true)
    }

    /// ChromeCookies 를 백그라운드 스레드에서 실행(동기 Keychain/SQLite 접근이 메인 액터를 막지 않게).
    private static func readChromeSessions() async throws -> ChromeCookies.Result {
        try await Task.detached(priority: .userInitiated) {
            try ChromeCookies.importSessionKeys()
        }.value
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
    /// - Parameters:
    ///   - automatic: 타이머/팝오버가 부른 호출. 백오프 중이면 건너뛴다(사용자가 누른 새로고침은 항상 실행).
    ///   - force: 방금 계정/세션 키를 바꿨으니 **반드시 새 회차가 필요하다**는 뜻.
    ///     진행 중이던 회차는 그 변경 이전 상태로 시작했기 때문에, 기다렸다 결과만 받으면
    ///     새 키가 반영되지 않은 실패가 화면에 그대로 남는다 (Chrome 가져오기 직후 계속 빨간 줄이 뜨던 원인).
    func refreshAll(automatic: Bool = false, force: Bool = false) async {
        if let running = refreshTask {
            let waitedId = refreshTaskId
            await running.value
            guard force else { return }
            // 기다리는 동안 다른 호출이 새 회차를 시작했다면 그쪽이 이미 최신 상태를 본다.
            // (`refreshTask` 자체는 끝난 회차가 아직 담겨 있을 수 있어 번호로 구분한다)
            if refreshTaskId != waitedId, let newer = refreshTask { await newer.value; return }
        }
        if automatic, let until = nextAutoRefreshAllowedAt, Date() < until { return }
        refreshTaskId += 1
        let myId = refreshTaskId
        let task = Task { @MainActor in await self.performRefresh() }
        refreshTask = task
        await task.value
        // 내 회차가 아직 최신일 때만 비운다 (그 사이 시작된 회차를 지워버리지 않게).
        if refreshTaskId == myId { refreshTask = nil }
        // 세션 만료가 남아 있고 자동 동기화가 켜져 있으면 Chrome 세션으로 되살려 본다.
        await maybeAutoRestoreFromChrome()
    }

    private func performRefresh() async {
        #if DEBUG
        if demoMode { rebuildMenuBarImage(); return }
        #endif
        guard !accounts.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 같은 sessionKey 를 쓰는 조직끼리 묶어 한 번의 브라우저 왕복으로 조회한다.
        // (WebSession 은 요청을 직렬화하므로, 계정마다 따로 부르면 계정 수만큼 줄을 서게 된다)
        var groups: [String: [Account]] = [:]
        for account in accounts where !account.sessionKey.isEmpty {
            groups[account.sessionKey, default: []].append(account)
        }
        for account in accounts where account.sessionKey.isEmpty {
            errors[account.id] = ClaudeAPIError.unauthorized.errorDescription
            expiredAccounts.insert(account.id)
        }

        var transientFailure = false
        var succeeded = 0
        for (key, group) in groups {
            let results = await ClaudeAPI.shared.fetchUsages(
                organizationIds: group.map(\.organizationId), sessionKey: key)
            for account in group {
                switch results[account.organizationId] {
                case .success(let u):
                    usage[account.id] = u
                    errors[account.id] = nil
                    expiredAccounts.remove(account.id)
                    succeeded += 1
                case .failure(let e):
                    errors[account.id] = e.errorDescription
                    if e.isTransient { transientFailure = true }
                    // 세션 만료(401/403)와 "이 세션에 없는 조직"(404)은 새로고침으로 안 풀린다 →
                    // 행에 바로 복구 버튼을 띄우고, 자동 동기화가 켜져 있으면 Chrome 키로 교체한다.
                    if e.needsReauth { expiredAccounts.insert(account.id) }
                    else { expiredAccounts.remove(account.id) }
                case nil:
                    errors[account.id] = ClaudeAPIError.noData.errorDescription
                    transientFailure = true
                }
            }
        }

        // 한 계정도 못 가져온 회차가 이어지면 브라우저 컨텍스트가 굳었을 가능성이 크다.
        // (오래 살아남은 WKWebView 하나로 계속 실패하던 실행본이 앱 재시작으로만 풀렸다)
        // 다음 회차가 새 WebKit 컨텍스트에서 시작하도록 버린다 — 대가는 챌린지 재통과 몇 초뿐이다.
        if !groups.isEmpty, succeeded == 0 {
            consecutiveEmptyRefreshes += 1
            if consecutiveEmptyRefreshes >= 2 {
                consecutiveEmptyRefreshes = 0
                WebSession.shared.resetContext()
            }
        } else {
            consecutiveEmptyRefreshes = 0
        }

        applyBackoff(failed: transientFailure)
        lastUpdated = Date()
        saveUsageCache()
        if notificationsEnabled {
            // 숨긴 한도로는 알리지 않는다 (UI 에 없는 값으로 알림만 뜨면 영문을 알 수 없다).
            let visible = usage.compactMapValues { displayed($0) }
            UsageNotifier.evaluate(accounts: accounts, usage: visible,
                                   threshold: Double(notificationThreshold))
        }
        rebuildMenuBarImage()
    }

    /// 차단/과호출/서버 오류가 이어지면 자동 새로고침 간격을 지수적으로 늘린다.
    /// (실패했는데도 5분마다 계속 두드리면 차단만 길어진다)
    private func applyBackoff(failed: Bool) {
        guard failed else {
            consecutiveFailures = 0
            nextAutoRefreshAllowedAt = nil
            return
        }
        consecutiveFailures += 1
        let base = TimeInterval(max(1, refreshMinutes) * 60)
        let delay = min(Self.maxBackoff, base * pow(2, Double(min(consecutiveFailures, 5))))
        nextAutoRefreshAllowedAt = Date().addingTimeInterval(delay)
    }

    // MARK: - 사용량 캐시 (재시작 직후 빈 화면 방지)

    private func saveUsageCache() {
        let snapshot = Dictionary(uniqueKeysWithValues: usage.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Keys.usageCache)
            UserDefaults.standard.set(lastUpdated, forKey: Keys.usageCachedAt)
        }
    }

    private func loadUsageCache() {
        guard let data = UserDefaults.standard.data(forKey: Keys.usageCache),
              let snapshot = try? JSONDecoder().decode([String: AccountUsage].self, from: data) else { return }
        let known = Set(accounts.map(\.id))
        for (idString, value) in snapshot {
            guard let id = UUID(uuidString: idString), known.contains(id) else { continue }
            usage[id] = value
        }
        lastUpdated = UserDefaults.standard.object(forKey: Keys.usageCachedAt) as? Date
    }

    /// 앱 실행 직후 1회: 타이머 시작 + 첫 새로고침 + 업데이트 확인.
    /// (예전에는 팝오버 onAppear 에서만 호출돼, 팝오버를 열기 전까지 메뉴바가 비어 있었다)
    func start() {
        restartTimer()
        observeAppearanceChanges()
        applyCachedUpdateInfo()
        Task { await refreshAll() }
        Task { await checkForUpdate() }
    }

    /// 다크/라이트 전환 시 메뉴바 이미지를 다시 그린다.
    /// (ImageRenderer 는 렌더 시점의 외형으로 픽셀을 굽기 때문에, 그대로 두면 색이 배경과 어긋난다)
    private func observeAppearanceChanges() {
        guard appearanceObserver == nil else { return }
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildMenuBarImage() }
        }
    }

    /// 팝오버를 열었을 때. onAppear 는 열 때마다 발생하므로 최소 간격 안이면 아무것도 하지 않는다.
    func onPopoverAppear() {
        if timer == nil { restartTimer() }
        if let last = lastUpdated, Date().timeIntervalSince(last) < Self.popoverRefreshMinInterval { return }
        Task { await refreshAll(automatic: true) }
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
            Task { @MainActor in await self?.refreshAll(automatic: true) }
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
