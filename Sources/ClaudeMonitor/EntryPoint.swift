//
//  EntryPoint.swift
//  ClaudeMonitor
//
//  실행 진입점. 환경변수 CTM_PREVIEW_OUT 이 지정되면 팝오버를 PNG 로 렌더링하고 종료(검증/스크린샷용),
//  아니면 메뉴바 앱을 실행한다.
//

import SwiftUI
import AppKit

@main
enum EntryPoint {
    static func main() {
        #if DEBUG
        // 개발 전용: 팝오버를 PNG 로 렌더링하고 종료 (README 미리보기 생성용)
        if let out = ProcessInfo.processInfo.environment["CTM_PREVIEW_OUT"] {
            MainActor.assumeIsolated {
                PreviewRenderer.render(to: out)
            }
            exit(0)
        }
        // 개발 전용: WebSession(=WKWebView fetch)이 Cloudflare 챌린지를 통과하는지 검증.
        // 잘못된 키여도 HTML("Just a moment")이 아니라 JSON(401/403)이 오면 우회 성공.
        // 사용법: CTM_WEBSESSION_TEST=1 [CTM_TEST_KEY=sk-ant-...] ./.build/debug/ClaudeMonitor
        if ProcessInfo.processInfo.environment["CTM_WEBSESSION_TEST"] != nil {
            MainActor.assumeIsolated {
                WebSessionProbe.run()
            }
            return
        }
        #endif
        ClaudeMonitorApp.main()
    }
}
