import Foundation
import MWDATCore

// Stubs for MWDATMockDevice, transcribed from the REAL DAT 0.8.0
// .swiftinterface. Note what is absent: there is no MockDisplayKit, and no
// GlassesModel has a display. `services` lives on `MockGlasses`, not on
// `MockDevice`.

public enum GlassesModel: String, CaseIterable, Sendable {
    case rayBanMeta, oakleyMetaHSTN, oakleyMetaVanguard, rayBanMetaOptics, metaGlasses
}

public enum CameraFacing: Sendable { case front, back }

public protocol MockCameraKit: Sendable {
    func setCameraFeed(fileURL: URL)
    func setCameraFeed(cameraFacing: CameraFacing) async
    func setCapturedImage(fileURL: URL)
}
public protocol MockCaptouchKit: Sendable {
    func tap()
    func tapAndHold()
}
public protocol MockDevice: Sendable {
    var deviceIdentifier: DeviceIdentifier { get }
    func powerOn()
    func powerOff()
    func don()
    func doff()
}
public protocol MockGlassesServices: Sendable {
    var camera: any MockCameraKit { get }
    var captouch: any MockCaptouchKit { get }
}
public protocol MockGlasses: MockDevice {
    func fold()
    func unfold()
    var services: any MockGlassesServices { get }
}

public enum MockDeviceKitError: Error, Sendable, Equatable { case notEnabled }

@frozen public struct MockDeviceKitConfig: Sendable {
    public let initiallyRegistered: Bool
    public let initialPermissionsGranted: Bool
    public init(initiallyRegistered: Bool = true, initialPermissionsGranted: Bool = true) {
        self.initiallyRegistered = initiallyRegistered
        self.initialPermissionsGranted = initialPermissionsGranted
    }
}

public protocol MockDeviceKitInterface: Sendable {
    var isEnabled: Bool { get }
    func enable(config: MockDeviceKitConfig)
    func disable()
    func pairGlasses(model: GlassesModel) throws(MockDeviceKitError) -> any MockGlasses
    func unpairDevice(_ device: any MockDevice)
    var pairedDevices: [any MockDevice] { get }
}
extension MockDeviceKitInterface {
    public func enable() { enable(config: MockDeviceKitConfig()) }
}

public enum MockDeviceKit: Sendable {
    public static let shared: any MockDeviceKitInterface = StubKit()
}

// ---- fakes ----
struct StubCamera: MockCameraKit {
    func setCameraFeed(fileURL: URL) {}
    func setCameraFeed(cameraFacing: CameraFacing) async {}
    func setCapturedImage(fileURL: URL) {}
}
struct StubCaptouch: MockCaptouchKit { func tap() {}; func tapAndHold() {} }
struct StubServices: MockGlassesServices {
    var camera: any MockCameraKit { StubCamera() }
    var captouch: any MockCaptouchKit { StubCaptouch() }
}
struct StubGlasses: MockGlasses {
    var deviceIdentifier: DeviceIdentifier { "mock" }
    func powerOn() {}; func powerOff() {}; func don() {}; func doff() {}
    func fold() {}; func unfold() {}
    var services: any MockGlassesServices { StubServices() }
}
struct StubKit: MockDeviceKitInterface {
    var isEnabled: Bool { true }
    func enable(config: MockDeviceKitConfig) {}
    func disable() {}
    func pairGlasses(model: GlassesModel) throws(MockDeviceKitError) -> any MockGlasses { StubGlasses() }
    func unpairDevice(_ device: any MockDevice) {}
    var pairedDevices: [any MockDevice] { [] }
}
