//
//  LoginItem.swift
//  ClaudeMonitor
//
//  로그인 시 자동 실행 토글. macOS 13+ SMAppService.mainApp 사용.
//  (raw 바이너리/미설치 상태에서는 register 가 실패할 수 있으므로 오류를 흡수한다.)
//

import Foundation
import ServiceManagement

enum LoginItem {
    /// 현재 로그인 항목으로 등록되어 있는지.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 사용자가 설정에서 직접 비활성화했는지 등(요청됨/거부됨)까지 구분이 필요하면 status 로.
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// 로그인 항목 등록/해제. 성공 여부 반환.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            return false
        }
    }
}
