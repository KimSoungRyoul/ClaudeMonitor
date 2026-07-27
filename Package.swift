// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeMonitor",
            path: "Sources/ClaudeMonitor",
            resources: [
                .process("Resources/AppIconImage.png")
            ],
            swiftSettings: [
                // Swift 5 언어 모드: 엄격한 동시성 검사로 인한 빌드 마찰을 피한다.
                .swiftLanguageMode(.v5)
            ]
        ),
        // UI 를 제외한 순수 로직(응답 파싱·버전 비교·시간 포맷·계정 저장 규칙) 검증.
        .testTarget(
            name: "ClaudeMonitorTests",
            dependencies: ["ClaudeMonitor"],
            path: "Tests/ClaudeMonitorTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
