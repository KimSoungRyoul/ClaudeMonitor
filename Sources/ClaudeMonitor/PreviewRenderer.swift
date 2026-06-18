//
//  PreviewRenderer.swift
//  ClaudeMonitor
//
//  팝오버 UI 를 데모 데이터로 PNG 로 렌더링한다. (헤드리스 빌드 검증/스크린샷용)
//

import SwiftUI
import AppKit

enum PreviewRenderer {
    @MainActor
    static func render(to path: String) {
        let state = AppState(demo: true)
        // 활성 계정을 샘플 B(=8%/19%) 로 맞춰 스크린샷이 풍부하게 보이도록
        if state.accounts.count > 1 {
            state.activeAccountId = state.accounts[1].id
        }
        // ScrollView/Menu 는 ImageRenderer 가 그리지 못하므로, 같은 구성요소를
        // 고정 VStack 으로 합성해 디자인을 캡처한다. (실제 앱에서는 PopoverView 사용)
        let view = VStack(spacing: 0) {
            PreviewHeader().environmentObject(state)
            Divider().opacity(0.5)
            UsageSections().environmentObject(state).padding(14)
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("데모 데이터 표시 중 — 메뉴 ‘…’ 에서 로그인")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("ClaudeMonitor").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .frame(width: 348)
        .background(Color(nsColor: .windowBackgroundColor))
        .fixedSize(horizontal: true, vertical: true)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0

        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("preview render failed\n".utf8))
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("preview written to \(path)")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        }
    }
}

/// 프리뷰 전용 헤더 (Menu 없이 — ImageRenderer 호환)
private struct PreviewHeader: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xD97757), Color(hex: 0xC15F3C)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                Image(systemName: "sparkle").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(state.activeAccount?.displayName ?? "ClaudeMonitor")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if let plan = state.activeAccount?.plan { PlanBadge(plan: plan) }
                    Text("데모")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Image(systemName: "ellipsis.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}
