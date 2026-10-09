import Foundation
import MWDATCore
import MWDATMockDevice

/// Stands up the official Mock Device Kit so the whole DAT path can be
/// demonstrated without physical glasses.
///
/// The kit intercepts the SDK below `DATWearableDevice`, so the app code is
/// **identical** on mock and on hardware — registration, permission grants,
/// stream lifecycle and `capturePhoto` all behave the same.
///
/// ## What the mock kit does not do
///
/// It emulates `MockCameraKit`, `MockCaptouchKit` and `MockPermissions`. As of
/// DAT 0.8.0 there is **no display emulation** — no `MockDisplayKit` exists,
/// and the paired model in every documented example is `.rayBanMeta`, which
/// has no display at all. So on this path:
///
///   * camera capture is real (served from the fixtures below),
///   * the HUD is rendered by the phone mirror instead of the glasses.
///
/// This is the single most important caveat for the demo: **the display half
/// of the assignment can only be shown on physical Ray-Ban Display hardware.**
/// The phone mirror is a faithful 600 × 600 stand-in, not the real panel.
/// `@MainActor` for a concrete reason, not out of habit. `pairedDevice` is
/// mutable state on a type with no isolation, which Swift 6 rejects outright
/// ("static property is not concurrency-safe"). Pinning the whole harness to
/// the main actor is the honest fix: it is only ever driven from app startup
/// and from a button in the phone UI, both of which are already main-actor.
@MainActor
enum MockDeviceKitHarness {

    /// Fixture video used as the live camera feed, and the still returned by
    /// `capturePhoto`. Both must be in the app bundle.
    ///
    /// The video must be **H.265**. The iOS sample transcodes automatically,
    /// but supplying H.264 to the kit directly produces a black feed. See the
    /// README for the ffmpeg command.
    struct Fixtures {
        let feedVideoName: String
        let capturedImageName: String

        static let walking = Fixtures(feedVideoName: "walking_feed", capturedImageName: "walking_still")
        static let running = Fixtures(feedVideoName: "running_feed", capturedImageName: "running_still")
        static let sitting = Fixtures(feedVideoName: "sitting_feed", capturedImageName: "sitting_still")
        static let standing = Fixtures(feedVideoName: "standing_feed", capturedImageName: "standing_still")
    }

    /// `any MockGlasses`, not `MockDevice`: in DAT 0.8.0 `services` (and so
    /// the camera kit) only exists on `MockGlasses`.
    private static var pairedDevice: (any MockGlasses)?

    /// Enables the kit and pairs one simulated pair of glasses. Call before
    /// `DATWearableDevice.connect()`.
    static func start(with fixtures: Fixtures) throws {
        let kit = MockDeviceKit.shared
        kit.enable()

        let device = try kit.pairGlasses(model: .rayBanMeta)
        // Both are required before the camera will stream: the kit models a
        // pair of glasses that is powered on and actually being worn.
        device.powerOn()
        device.don()

        try load(fixtures, into: device)
        pairedDevice = device
    }

    /// Swaps the fixture between trials, so one run can cover all four
    /// activities without restarting the app.
    static func use(_ fixtures: Fixtures) throws {
        guard let pairedDevice else { return }
        try load(fixtures, into: pairedDevice)
    }

    private static func load(_ fixtures: Fixtures, into device: any MockGlasses) throws {
        guard let feed = Bundle.main.url(forResource: fixtures.feedVideoName, withExtension: "mp4") else {
            throw MockFixtureError.missing("\(fixtures.feedVideoName).mp4")
        }
        guard let still = Bundle.main.url(forResource: fixtures.capturedImageName, withExtension: "jpg") else {
            throw MockFixtureError.missing("\(fixtures.capturedImageName).jpg")
        }
        device.services.camera.setCameraFeed(fileURL: feed)
        device.services.camera.setCapturedImage(fileURL: still)
    }

    static func stop() {
        MockDeviceKit.shared.disable()
        pairedDevice = nil
    }

    enum MockFixtureError: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let name):
                "Mock fixture \"\(name)\" is not in the app bundle — see README ▸ Mock Device Kit."
            }
        }
    }
}
