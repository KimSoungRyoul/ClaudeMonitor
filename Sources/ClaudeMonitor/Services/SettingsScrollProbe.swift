//
//  SettingsScrollProbe.swift
//  ClaudeMonitor
//
//  개발 전용 검증 도구. 설정 창이 실제로 스크롤되는지 확인한다.
//  설정 창에는 한때 ScrollView 가 없어(고정 VStack + .frame(height:580), 창도 리사이즈 불가),
//  계정이 몇 개만 늘어도 내용이 잘린 채 마우스 휠이 아무 반응도 하지 않았다.
//  사용법: CTM_SETTINGS_TEST=1 [CTM_SETTINGS_HOLD=<초>] ./.build/debug/ClaudeMonitor
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum SettingsScrollProbe {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        /// 캡처용 유지 시간 (CTM_SETTINGS_HOLD=<초>). 안전장치 타임아웃은 이보다 길어야 한다.
        let hold = ProcessInfo.processInfo.environment["CTM_SETTINGS_HOLD"].flatMap(Double.init) ?? 0

        let state = AppState(demo: true)
        // 내용이 창보다 확실히 길도록 계정을 채운다 (버그를 신고한 사용자의 9개 계정 재현).
        // 창을 띄우기 전에 값을 넣어야 SettingsView 의 onChange(알림 권한 요청)가 뜨지 않는다.
        state.accounts = (1...9).map {
            Account(id: UUID(), organizationId: "demo-\($0)",
                    organizationName: "Demo · Org \($0)", plan: .max)
        }
        state.activeAccountId = state.accounts.first?.id
        WindowManager.shared.attach(state: state)
        WindowManager.shared.openSettings()

        Task { @MainActor in
            guard let window = WindowManager.shared.debugSettingsWindow else {
                print("SETTINGS: ❌ no settings window")
                exit(2)
            }
            // 허용된 가장 작은 크기로 줄여 반드시 오버플로 상태로 만든다 (최소 크기도 함께 확인).
            window.setContentSize(NSSize(width: 480, height: 320))
            try? await Task.sleep(nanoseconds: 800_000_000)   // SwiftUI 레이아웃 완료 대기

            print("SETTINGS: window content=\(fmt(window.contentLayoutRect.size))"
                  + " minFrame=\(fmt(window.minSize))"
                  + " resizable=\(window.styleMask.contains(.resizable))")
            if !window.styleMask.contains(.resizable) {
                print("SETTINGS: ❌ NOT RESIZABLE (내용이 넘쳐도 창을 키울 수 없다)")
                exit(1)
            }

            guard let content = window.contentView, let scroll = firstScrollView(in: content) else {
                print("SETTINGS: ❌ NO SCROLL VIEW (스크롤 컨테이너가 없어 휠이 먹지 않는다)")
                exit(1)
            }
            let docHeight = scroll.documentView?.frame.height ?? 0
            let visibleHeight = scroll.contentView.bounds.height
            print("SETTINGS: content=\(Int(docHeight))pt visible=\(Int(visibleHeight))pt"
                  + " overflow=\(Int(docHeight - visibleHeight))pt")
            guard docHeight > visibleHeight + 1 else {
                print("SETTINGS: ❌ content fits — 오버플로를 못 만들어 스크롤을 검증할 수 없다")
                exit(1)
            }

            // 실제 휠 이벤트로 문서가 움직이는지 (프로세스 내부 전달이라 접근성 권한이 필요 없다).
            let before = scroll.documentVisibleRect.origin.y
            scrollWheel(on: scroll, lines: -6)
            try? await Task.sleep(nanoseconds: 300_000_000)
            var after = scroll.documentVisibleRect.origin.y
            if abs(after - before) < 0.5 {   // 문서 뷰가 flipped 인지에 따라 부호가 뒤집힌다
                scrollWheel(on: scroll, lines: 6)
                try? await Task.sleep(nanoseconds: 300_000_000)
                after = scroll.documentVisibleRect.origin.y
            }
            print("SETTINGS: visibleRect.y \(Int(before)) → \(Int(after))")
            if abs(after - before) < 0.5 {
                print("SETTINGS: ❌ WHEEL DID NOTHING")
                exit(1)
            }
            print("SETTINGS: ✅ WHEEL SCROLLS (\(Int(abs(after - before)))pt moved)")

            // CTM_SETTINGS_HOLD=<초>: 기본 크기로 되돌려 screencapture -l<번호> 로 찍는 용도.
            if hold > 0 {
                window.setContentSize(NSSize(width: 480, height: 580))
                print("SETTINGS: holding \(Int(hold))s · window number \(window.windowNumber)")
                try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            }
            exit(0)
        }
        // 안전장치: 무한 대기 방지. 캡처용 유지 시간보다 길어야 관찰 도중에 죽지 않는다.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((60 + hold) * 1_000_000_000))
            print("SETTINGS: timeout")
            exit(2)
        }
        app.run()
    }

    private static func fmt(_ size: NSSize) -> String { "\(Int(size.width))x\(Int(size.height))" }

    private static func scrollWheel(on view: NSView, lines: Int32) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                               wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else {
            print("SETTINGS: ⚠️ could not synthesize a wheel event")
            return
        }
        view.scrollWheel(with: event)
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let scroll = firstScrollView(in: sub) { return scroll }
        }
        return nil
    }
}
#endif
