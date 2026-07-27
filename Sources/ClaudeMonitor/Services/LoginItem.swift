//
//  LoginItem.swift
//  ClaudeMonitor
//
//  로그인 시 자동 실행(로그인 항목) 등록. 메뉴바 유틸리티의 기본 동작이다.
//  SMAppService 는 번들된 .app 에서만 동작하므로, 개발용 raw 바이너리에서는 사용 불가로 처리한다.
//

import Foundation
import ServiceManagement

enum LoginItem {
    /// 이 실행 파일이 로그인 항목으로 등록될 수 있는가 (.app 번들로 실행 중인가)
    static var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// 등록/해제. 실패 사유를 문자열로 돌려준다(성공이면 nil).
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard isSupported else {
            return L.s("번들로 실행할 때만 설정할 수 있습니다.", "Only available when running from the app bundle.")
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
