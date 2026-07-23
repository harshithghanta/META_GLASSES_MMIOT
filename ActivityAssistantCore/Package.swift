// swift-tools-version: 6.0
import PackageDescription

// ActivityAssistantCore holds every piece of the app that does not need the
// glasses, the phone camera, or UIKit: the flow state machine, the ImageBind
// client, and the display-frame model.  Keeping it in its own package is what
// lets the whole interaction be exercised on a laptop with no hardware and no
// DAT entitlement.
//
// The checks live in an executable rather than a `testTarget` on purpose:
// XCTest and swift-testing both require a full Xcode install, and the point of
// this package is that it verifies on any machine with the Swift toolchain.
//     swift run corecheck            # run every check
//     swift run corecheck --trials   # regenerate the eight-trial table
let package = Package(
    name: "ActivityAssistantCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ActivityAssistantCore", targets: ["ActivityAssistantCore"]),
        .executable(name: "corecheck", targets: ["CoreCheck"]),
    ],
    targets: [
        .target(name: "ActivityAssistantCore"),
        .executableTarget(name: "CoreCheck", dependencies: ["ActivityAssistantCore"]),
    ]
)
