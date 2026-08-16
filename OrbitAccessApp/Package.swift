// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OrbitAccessApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OrbitAccessApp", targets: ["OrbitAccessApp"]),
    ],
    dependencies: [
        // GRDB was removed in plan 51 Phase 3B. It is built against system SQLite
        // (`CSQLite` as a `.systemLibrary`), and `~/.orbit/orbit.db` is SQLCipher-encrypted,
        // so every connection failed GRDB's `SELECT * FROM sqlite_master LIMIT 1` validation
        // with SQLITE_NOTADB. GRDB's SQLCipher flavour is CocoaPods-only — there is no SPM
        // product — so the app reads the store over localhost HTTP instead (decision D1).
        // Do not add it back without reopening that decision.
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.0.0"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "OrbitAccessApp",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "PostHog", package: "posthog-ios"),
            ],
            path: ".",
            exclude: [
                "ISSUE_REPORT.md",
                "OrbitAccessApp.xcodeproj",
                "project.yml",
                "OrbitAccessApp.entitlements",
                "Resources/Info.plist",
                "Resources/Info.bundle.plist",
                "Resources/orbit-icon.svg",
                "Package.swift",
            ],
            sources: [
                "App",
                "IPC",
                "Models",
                "Services",
                "Stores",
                "AIFunctions",
                "Extensions",
                "Views",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
