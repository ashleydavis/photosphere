// swift-tools-version:5.7

import PackageDescription

// Ziggy's shell code for iOS: owns the WKWebView, injects window.ziggy, and moves messages between the page and the Zig
// core through the C interface in ziggy.h. The Zig static library itself (libziggy_example.a for an app) is linked by the app
// project, not by this package.
let package = Package(
    name: "ZiggyShellIOS",
    platforms: [
        .iOS(.v14),
    ],
    products: [
        .library(
            name: "ZiggyShellIOS",
            targets: ["ZiggyShellIOS"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CZiggy",
            path: "Sources/CZiggy"
        ),
        .target(
            name: "ZiggyShellIOS",
            dependencies: ["CZiggy"]
        ),
    ]
)
