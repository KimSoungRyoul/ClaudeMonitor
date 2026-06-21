//
//  SettingsView.swift
//  ClaudeMonitor
//
//  설정 창: 계정 관리(별칭/삭제), 새로고침 주기, 정보.
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
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

                // 일반: 언어 / 메뉴바 표시 / 로그인 자동실행
                GroupBox(L.s("일반", "General")) {
                    VStack(spacing: 10) {
                        settingRow(L.s("표시 언어", "Display language")) {
                            Picker("", selection: $state.language) {
                                ForEach(AppLanguage.allCases) { lang in
                                    Text(lang.label).tag(lang)
                                }
                            }
                            .labelsHidden().frame(width: 120)
                        }
                        Divider()
                        settingRow(L.s("메뉴바 표시", "Menu-bar display")) {
                            Picker("", selection: $state.menuBarMode) {
                                ForEach(MenuBarMode.allCases) { m in Text(m.label).tag(m) }
                            }
                            .labelsHidden().frame(width: 140)
                        }
                        Divider()
                        LoginAtLoginRow()
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

                // 알림
                GroupBox(L.s("알림", "Notifications")) {
                    VStack(spacing: 10) {
                        Toggle(isOn: $state.notificationsEnabled) {
                            Text(L.s("사용량 임계치 알림", "Usage threshold alerts"))
                        }
                        if state.notificationsEnabled {
                            Divider()
                            settingRow(L.s("알림 임계치", "Alert threshold")) {
                                Picker("", selection: $state.notifyThreshold) {
                                    Text("70%").tag(70)
                                    Text("80%").tag(80)
                                    Text("90%").tag(90)
                                    Text("95%").tag(95)
                                }
                                .labelsHidden().frame(width: 90)
                            }
                            Text(L.s("5시간/7일 사용량이 임계치를 처음 넘을 때 알림을 보냅니다.",
                                     "Notifies once when 5h/7d usage first crosses the threshold."))
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }

                // 위젯 안내
                GroupBox(L.s("위젯", "Widget")) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(Color(hex: 0xD97757))
                        Text(L.s("데스크탑/알림 센터에서 위젯 갤러리를 열고 ‘Claude Usage’를 추가하면 계정별 5시간·7일 사용량을 볼 수 있습니다.",
                                 "Open the widget gallery (desktop / Notification Center) and add ‘Claude Usage’ to see 5-hour / 7-day usage per account."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
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
            }
            .padding(20)
        }
        .frame(width: 480, height: 540)
    }

    /// 라벨 + 우측 컨트롤 한 줄
    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer()
            content()
        }
    }
}

/// 로그인 시 자동 실행 토글 (SMAppService 상태와 동기화)
private struct LoginAtLoginRow: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var failed = false

    var body: some View {
        HStack {
            Text(L.s("로그인 시 자동 실행", "Launch at login"))
            Spacer()
            if failed {
                Text(L.s("설정 실패", "Failed"))
                    .font(.caption).foregroundStyle(.red)
            }
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { newValue in
                    let ok = LoginItem.setEnabled(newValue)
                    failed = !ok
                    enabled = LoginItem.isEnabled
                }))
            .labelsHidden()
        }
        .onAppear { enabled = LoginItem.isEnabled }
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
