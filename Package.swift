// swift-tools-version:5.9
//
// Paprika — Apple Silicon 맥북 배터리 충전 제한 앱
//
// 구성:
//   PaprikaKit  — SMC/배터리/정책 등 앱과 데몬이 함께 쓰는 코드
//   paprikad    — root 권한 LaunchDaemon (실제 SMC 쓰기를 담당)
//   Paprika     — 메뉴바 앱 (Paprika.app 번들 안에 들어감)
//   paprikactl  — 진단용 커맨드라인 도구
//
// swift-tools-version 을 5.9 로 둔 이유: Swift 6 의 strict concurrency 검사를
// 켜지 않기 위해서다. (툴체인이 Swift 6 이어도 언어 모드는 5 로 동작한다)

import PackageDescription

let package = Package(
    name: "Paprika",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Paprika", targets: ["Paprika"]),
        .executable(name: "paprikad", targets: ["paprikad"]),
        .executable(name: "paprikactl", targets: ["paprikactl"]),
        .library(name: "PaprikaKit", targets: ["PaprikaKit"]),
    ],
    targets: [
        .target(
            name: "PaprikaKit",
            path: "Sources/PaprikaKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "Paprika",
            dependencies: ["PaprikaKit"],
            path: "Sources/Paprika",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "paprikad",
            dependencies: ["PaprikaKit"],
            path: "Sources/paprikad",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "paprikactl",
            dependencies: ["PaprikaKit"],
            path: "Sources/paprikactl",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
