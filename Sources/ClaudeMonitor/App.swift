//
//  App.swift
//  ClaudeMonitor
//
//  메뉴바 앱 본체. MenuBarExtra(.window) 로 컬러 라벨 + 팝오버를 띄운다.
//

import SwiftUI
import AppKit

struct ClaudeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    init() {
        // WindowManager 에 상태 연결은 onAppear 시점에 (StateObject 접근)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(state)
                .onAppear {
                    WindowManager.shared.attach(state: state)
                    state.startTimer()
                }
        } label: {
            Image(nsImage: state.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 앱 델리게이트: accessory 정책으로 Dock 아이콘 숨김.
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    /// 개발 데모 창용 상태 (강한 참조 유지)
    private var demoState: AppState?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        // 개발 전용: 실제 PopoverView 를 창으로 띄워 캡처 가능하게 한다.
        if ProcessInfo.processInfo.environment["CTM_WINDOW_DEMO"] == "1" {
            let s = AppState(demo: true)
            demoState = s
            WindowManager.shared.attach(state: s)
            WindowManager.shared.openDemoPopover()
        }
        #endif
    }
}

/// 로그인/설정 창을 관리하는 싱글톤 (AppKit NSWindow + NSHostingController)
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private weak var state: AppState?
    private var loginWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var demoWindow: NSWindow?

    func attach(state: AppState) { self.state = state }

    /// 검증용: 실제 PopoverView 를 fit-to-content 창으로 띄운다 (MenuBarExtra 와 동일한 자동 크기).
    func openDemoPopover() {
        guard let state else { return }
        // 검증용 언어 강제(CTM_LANG=en|ko)
        if let lng = ProcessInfo.processInfo.environment["CTM_LANG"],
           let al = AppLanguage(rawValue: lng) { state.language = al }
        state.demoMode = true
        state.activeAccountId = DemoData.ids[0]   // 5h+7d 둘 다 있는 계정으로 (듀얼 링 확인)
        state.rebuildMenuBarImage()
        let hosting = NSHostingController(rootView: PopoverView().environmentObject(state))
        let window = NSWindow(contentViewController: hosting)   // 콘텐츠 fitting size 로 자동
        window.title = "Popover Preview"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating   // 검증 캡처를 위해 항상 위
        if let screen = NSScreen.main {
            let top = screen.frame.maxY
            window.setFrameTopLeftPoint(NSPoint(x: screen.frame.minX + 60, y: top - 60))
        }
        demoWindow = window
        bringToFront(window)
    }

    func openLogin() {
        guard let state else { return }
        if let w = loginWindow { bringToFront(w); return }
        let view = WebLoginView(onClose: { [weak self] in self?.loginWindow?.close() })
            .environmentObject(state)
        let window = makeWindow(title: L.s("Claude 로그인", "Claude Login"), view: view,
                                size: NSSize(width: 560, height: 620))
        loginWindow = window
        bringToFront(window)
    }

    func openSettings() {
        guard let state else { return }
        if let w = settingsWindow { bringToFront(w); return }
        let view = SettingsView().environmentObject(state)
        let window = makeWindow(title: L.s("설정", "Settings"), view: view,
                                size: NSSize(width: 480, height: 540))
        settingsWindow = window
        bringToFront(window)
    }

    private func makeWindow<V: View>(title: String, view: V, size: NSSize) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)   // 창을 보이게 하려면 일시적으로 regular
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w == loginWindow { loginWindow = nil }
        if w == settingsWindow { settingsWindow = nil }
        if w == demoWindow { demoWindow = nil }
        // 열린 보조 창이 없으면 다시 accessory 로 (Dock 아이콘 숨김)
        if loginWindow == nil && settingsWindow == nil && demoWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
