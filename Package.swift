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
            swiftSettings: [
                // Swift 5 언어 모드: 엄격한 동시성 검사로 인한 빌드 마찰을 피한다.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
