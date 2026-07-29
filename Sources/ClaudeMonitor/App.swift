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
    /// AppDelegate(실행 직후 갱신 시작)와 같은 인스턴스를 공유한다.
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(state)
                // onAppear 는 팝오버를 열 때마다 발생한다 → 여기서 갱신은 최소 간격으로 스로틀한다.
                .onAppear { state.onPopoverAppear() }
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
            return
        }
        #endif
        // 팝오버를 한 번도 열지 않아도 메뉴바가 채워지도록 실행 직후 갱신을 시작한다.
        WindowManager.shared.attach(state: .shared)
        AppState.shared.start()
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

    #if DEBUG
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
    #endif

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
        // 계정이 늘면 내용이 기본 높이를 넘는다 → 스크롤(SettingsView)에 더해 창도 키울 수 있게 한다.
        // 최소 크기는 SettingsView 루트의 frame(minWidth:minHeight:) 이 정한다.
        let window = makeWindow(title: L.s("설정", "Settings"), view: view,
                                size: NSSize(width: 480, height: 580),
                                resizable: true)
        settingsWindow = window
        bringToFront(window)
    }

    #if DEBUG
    /// 검증용: 열려 있는 설정 창 (SettingsScrollProbe 가 스크롤 가능 여부를 확인한다).
    var debugSettingsWindow: NSWindow? { settingsWindow }
    #endif

    private func makeWindow<V: View>(title: String, view: V, size: NSSize,
                                     resizable: Bool = false) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        // 기본값 .preferredContentSize 는 SwiftUI 이상 크기가 바뀔 때마다 창을 되돌려 사용자가
        // 늘린 크기를 무시한다. .minSize 만 켜서 루트 뷰의 최소 크기를 창 한계로 쓴다
        // (window.minSize 직접 지정은 Auto Layout 콘텐츠에서 AppKit 이 다시 덮어쓴다).
        if resizable { hosting.sizingOptions = [.minSize] }
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
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
