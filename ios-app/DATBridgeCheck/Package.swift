// swift-tools-version: 6.0
import PackageDescription

// Type-checks the Device Access Toolkit bridge on a laptop.
//
// The real DAT SDK ships as binary iOS xcframeworks, so the bridge cannot be
// built without Xcode and the iOS SDK. This package type-checks it on a Mac
// instead.
//
// `Sources/MWDAT*` are stubs transcribed from the REAL DAT 0.8.0 public
// `.swiftinterface` files (github.com/facebook/meta-wearables-dat-ios, tag
// 0.8.0). They mirror every symbol the app uses: names, optionality, typed
// throws and async. `Sources/DATBridge` contains SYMLINKS to the real app
// sources, so there is exactly one copy of the bridge.
//
//     cd ios-app/DATBridgeCheck && swift build
//
// ## What this does and does not show
//
// SHOWS: the bridge type-checks under Swift 6 against the SDK's public API as
// transcribed into these stubs.
//
// DOES NOT SHOW: runtime behaviour (state transitions, callbacks, reentrancy,
// continuation handling in practice), or that the transcription is
// error-free. When the SDK version changes, re-diff the stubs against the new
// .swiftinterface. `ActivityAssistantApp.swift`, `HFPAudioRecorder.swift`
// and `GlassesSpeaker.swift` are NOT included: they need iOS-only APIs.
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
