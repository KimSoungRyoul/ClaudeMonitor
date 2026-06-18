//
//  SettingsView.swift
//  ClaudeMonitor
//
//  설정 창: 계정 관리(별칭/삭제), 새로고침 주기, 정보.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
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

            Spacer()

            HStack {
                Toggle(L.s("데모 모드", "Demo mode"), isOn: Binding(
                    get: { state.demoMode },
                    set: { state.demoMode = $0; state.rebuildMenuBarImage() }))
                Spacer()
                Text(L.s("ClaudeMonitor v\(state.appVersion) · 멀티 계정 Claude 사용량 모니터",
                         "ClaudeMonitor v\(state.appVersion) · Multi-account Claude usage monitor"))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
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
