//
//  ClaudeMonitorWidget.swift
//  ClaudeMonitorWidget
//
//  WidgetKit 확장 진입점. SnapshotStore(App Group)에서 사용량 스냅샷을 읽어
//  small/medium/large 위젯으로 렌더링한다. 메인 앱이 새로고침할 때마다
//  WidgetCenter.reloadAllTimelines() 로 갱신을 트리거한다.
//

import WidgetKit
import SwiftUI
import ClaudeMonitorShared

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: UsageSnapshot.placeholder(referenceDate: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let snap = SnapshotStore.load() ?? (context.isPreview ? UsageSnapshot.placeholder(referenceDate: Date()) : nil)
        completion(UsageEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snap = SnapshotStore.load()
        let now = Date()
        // 남은 시간 카운트다운이 부드럽게 갱신되도록 1시간 동안 몇 개의 엔트리를 만든다.
        let offsets: [TimeInterval] = [0, 600, 1_200, 1_800, 2_700, 3_600]
        let entries = offsets.map { UsageEntry(date: now.addingTimeInterval($0), snapshot: snap) }
        // 마지막 엔트리 이후 다시 타임라인 재요청(앱이 살아있으면 그 전에 reload 가 들어온다).
        let timeline = Timeline(entries: entries, policy: .after(now.addingTimeInterval(3_600)))
        completion(timeline)
    }
}

// MARK: - Entry View

struct ClaudeMonitorWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: UsageEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.accounts.isEmpty {
                switch family {
                case .systemSmall:
                    if let acc = snapshot.activeAccount {
                        SmallWidgetView(account: acc, now: entry.date)
                    } else { WidgetEmptyView() }
                case .systemMedium:
                    MediumWidgetView(snapshot: snapshot, now: entry.date)
                case .systemLarge:
                    LargeWidgetView(snapshot: snapshot, now: entry.date)
                default:
                    if let acc = snapshot.activeAccount {
                        SmallWidgetView(account: acc, now: entry.date)
                    } else { WidgetEmptyView() }
                }
            } else {
                WidgetEmptyView()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget

struct ClaudeMonitorWidget: Widget {
    let kind: String = SharedConstants.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            ClaudeMonitorWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description(WidgetL.s("계정별 Claude 5시간·7일 사용량.", "Claude 5-hour / 7-day usage per account."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Bundle (@main)

@main
struct ClaudeMonitorWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeMonitorWidget()
    }
}
