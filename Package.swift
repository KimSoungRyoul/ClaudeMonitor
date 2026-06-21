// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // 앱과 위젯이 공유하는 순수 Foundation 레이어 (스냅샷 모델 + 저장소)
        .target(
            name: "ClaudeMonitorShared",
            path: "Sources/ClaudeMonitorShared",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // 메뉴바 앱 본체
        .executableTarget(
            name: "ClaudeMonitor",
            dependencies: ["ClaudeMonitorShared"],
            path: "Sources/ClaudeMonitor",
            resources: [
                .process("Resources/AppIconImage.png")
            ],
            swiftSettings: [
                // Swift 5 언어 모드: 엄격한 동시성 검사로 인한 빌드 마찰을 피한다.
                .swiftLanguageMode(.v5)
            ]
        ),
        // WidgetKit 확장 (빌드 후 build_app.sh 가 .appex 로 조립해 .app 에 임베드)
        .executableTarget(
            name: "ClaudeMonitorWidget",
            dependencies: ["ClaudeMonitorShared"],
            path: "Sources/ClaudeMonitorWidget",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
