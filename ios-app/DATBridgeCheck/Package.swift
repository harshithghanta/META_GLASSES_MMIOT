// swift-tools-version: 6.0
import PackageDescription

// Type-checks the Device Access Toolkit bridge on a laptop.
//
// The real DAT SDK ships as binary xcframeworks behind a Meta developer
// account, so the bridge could not be compiled at all during development —
// and an uncompiled 300-line concurrency-heavy file is exactly where bugs
// hide. Two of them did: an actor-isolated continuation mutated from a
// `@Sendable` closure (a hard error even in Swift 5 mode) and a task group
// that deadlocked on timeout.
//
// `Sources/MWDAT*` are hand-written stubs matching the *shape* of the DAT
// 0.8.0 API as documented. `Sources/DATBridge` contains SYMLINKS to the real
// app sources, so there is exactly one copy of the bridge and it cannot drift
// from what this checks.
//
//     cd ios-app/DATBridgeCheck && swift build
//
// ## What this does and does not prove
//
// PROVES: the bridge is internally consistent, actor isolation is correct,
// continuations are resumed exactly once, and it compiles under Swift 6
// strict concurrency.
//
// DOES NOT PROVE: that the stub signatures match the real SDK. They are
// written from Meta's published API reference, not from the binary. Expect to
// reconcile names on the first real Xcode build — but the *logic* is checked.
let package = Package(
    name: "DATBridgeCheck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DATBridge", targets: ["DATBridge"])
    ],
    dependencies: [
        .package(path: "../../ActivityAssistantCore")
    ],
    targets: [
        .target(name: "MWDATCore"),
        .target(name: "MWDATCamera", dependencies: ["MWDATCore"]),
        .target(name: "MWDATDisplay", dependencies: ["MWDATCore"]),
        .target(name: "MWDATMockDevice", dependencies: ["MWDATCore"]),
        .target(
            name: "DATBridge",
            dependencies: [
                .product(name: "ActivityAssistantCore", package: "ActivityAssistantCore"),
                "MWDATCore", "MWDATCamera", "MWDATDisplay", "MWDATMockDevice",
            ]
        ),
    ]
)
