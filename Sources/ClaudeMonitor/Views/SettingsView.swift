//
//  SettingsView.swift
//  ClaudeMonitor
//
//  설정 창: 계정 관리(별칭/삭제), 새로고침 주기, 정보.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var notificationError: String?

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // fit-to-content 창(NSHostingController)에서 ScrollView 는 이상 높이가 없으면 접힌다 →
        // 창의 기본 크기를 이상 크기로 못박고, 사용자가 늘리면 그만큼 채운다.
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity,
               minHeight: 320, idealHeight: 580, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L.s("설정", "Settings")).font(.title2.bold())
                Spacer()
                Button {
                    WindowManager.shared.openLogin()
                } label: {
                    Label(L.s("계정 추가", "Add account"), systemImage: "plus")
                }
            }

            // 언어
            GroupBox(L.s("언어", "Language")) {
                HStack {
                    Text(L.s("표시 언어", "Display language"))
                    Spacer()
                    Picker("", selection: $state.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                .padding(6)
            }

            // 시작 & 알림
            GroupBox(L.s("일반", "General")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L.s("로그인 시 자동 실행", "Launch at login"), isOn: $launchAtLogin)
                        .disabled(!LoginItem.isSupported)
                        .onChange(of: launchAtLogin) { _, newValue in
                            loginItemError = LoginItem.set(newValue)
                            if loginItemError != nil { launchAtLogin = LoginItem.isEnabled }
                        }
                    if let loginItemError {
                        Text(loginItemError).font(.caption).foregroundStyle(.orange)
                    }

                    Toggle(L.s("사용량이 임계값을 넘으면 알림", "Notify when usage crosses a threshold"),
                           isOn: $state.notificationsEnabled)
                        .onChange(of: state.notificationsEnabled) { _, newValue in
                            guard newValue else { notificationError = nil; return }
                            Task {
                                let granted = await UsageNotifier.requestAuthorization()
                                if !granted {
                                    state.notificationsEnabled = false
                                    notificationError = L.s("알림 권한이 없습니다. 시스템 설정 > 알림에서 허용해 주세요.",
                                                            "Notifications are not allowed. Enable them in System Settings › Notifications.")
                                } else {
                                    notificationError = nil
                                }
                            }
                        }
                    if state.notificationsEnabled {
                        HStack {
                            Text(L.s("임계값", "Threshold"))
                            Picker("", selection: $state.notificationThreshold) {
                                ForEach([70, 80, 90, 95], id: \.self) { Text("\($0)%").tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 90)
                            Spacer()
                        }
                    }
                    if let notificationError {
                        Text(notificationError).font(.caption).foregroundStyle(.orange)
                    }

                    Divider()

                    Toggle(L.s("세션 만료 시 Chrome 에서 자동으로 되살리기",
                               "Restore expired sessions from Chrome automatically"),
                           isOn: $state.chromeAutoSync)
                    Text(L.s("켜면 세션이 만료된 계정을 로그인된 Chrome 세션으로 조용히 되살립니다. 처음 켤 때 브라우저의 Keychain 접근을 한 번 허용해야 합니다.",
                             "When on, expired accounts are silently restored from your logged-in Chrome session. The first time, you must allow access to the browser’s Keychain item once."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Toggle(L.s("모델별 주간 사용량 조회 (Fable)", "Track per-model weekly usage (Fable)"),
                           isOn: $state.showModelLimits)
                    Text(L.s("끄면 Fable 등 모델별 주간 한도(f7d) 링과 알림을 표시하지 않습니다. 5시간·7일 사용량만 봅니다.",
                             "When off, per-model weekly rings (f7d) and their notifications are hidden — only 5-hour / 7-day usage is shown."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 새로고침 주기
            GroupBox(L.s("새로고침", "Refresh")) {
                HStack {
                    Text(L.s("자동 새로고침 주기", "Auto-refresh interval"))
                    Spacer()
                    Picker("", selection: $state.refreshMinutes) {
                        Text(L.s("1분", "1 min")).tag(1)
                        Text(L.s("3분", "3 min")).tag(3)
                        Text(L.s("5분", "5 min")).tag(5)
                        Text(L.s("10분", "10 min")).tag(10)
                        Text(L.s("30분", "30 min")).tag(30)
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    Button(L.s("지금 새로고침", "Refresh now")) { Task { await state.refreshAll() } }
                }
                .padding(6)
            }

            // 계정 목록
            GroupBox(L.s("계정 (\(state.accounts.count))", "Accounts (\(state.accounts.count))")) {
                if state.accounts.isEmpty {
                    Text(L.s("등록된 계정이 없습니다. ‘계정 추가’로 로그인하세요.", "No accounts yet. Use ‘Add account’ to log in."))
                        .foregroundStyle(.secondary).padding(8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(state.accounts) { account in
                            AccountSettingsRow(account: account)
                            if account.id != state.accounts.last?.id { Divider() }
                        }
                    }
                    .padding(4)
                }
            }

            HStack {
                #if DEBUG
                Toggle(L.s("데모 모드", "Demo mode"), isOn: Binding(
                    get: { state.demoMode },
                    set: { state.demoMode = $0; state.rebuildMenuBarImage() }))
                #endif
                Spacer()
                Text(L.s("ClaudeMonitor v\(state.appVersion) · 멀티 계정 Claude 사용량 모니터",
                         "ClaudeMonitor v\(state.appVersion) · Multi-account Claude usage monitor"))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
    }
}

private struct AccountSettingsRow: View {
    @EnvironmentObject var state: AppState
    let account: Account
    @State private var alias: String = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField(L.s("별칭", "Alias"), text: $alias, onCommit: commit)
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                } else {
                    Text(account.displayName).font(.system(size: 13, weight: .medium))
                }
                Text(account.organizationName).font(.caption).foregroundStyle(.secondary)
            }
            PlanBadge(plan: account.plan)
            Spacer()
            if account.sessionKey.isEmpty {
                Text(L.s("세션 없음", "No session")).font(.caption).foregroundStyle(.red)
            }
            Button(editing ? L.s("저장", "Save") : L.s("별칭", "Alias")) {
                if editing { commit() } else { alias = account.alias ?? ""; editing = true }
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) { state.removeAccount(account) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private func commit() {
        state.setAlias(alias.isEmpty ? nil : alias, for: account)
        editing = false
    }
}
