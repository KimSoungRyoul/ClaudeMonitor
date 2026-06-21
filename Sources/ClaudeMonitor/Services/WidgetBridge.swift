//
//  WidgetBridge.swift
//  ClaudeMonitor
//
//  앱 → 위젯 갱신 트리거. 스냅샷을 새로 쓴 뒤 위젯 타임라인을 리로드한다.
//  (정상 번들이 아닌 raw 바이너리/프리뷰 경로에서는 안전하게 무시)
//

import Foundation
import WidgetKit
import ClaudeMonitorShared

enum WidgetBridge {
    /// 위젯 타임라인 전체 리로드. 번들 ID 가 없으면(테스트/프리뷰) 아무 것도 하지 않는다.
    static func reload() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: SharedConstants.widgetKind)
    }
}
