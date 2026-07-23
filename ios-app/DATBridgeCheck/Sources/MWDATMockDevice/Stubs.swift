import Foundation
import MWDATCore

// Shape-only stubs for MWDATMockDevice (DAT 0.8.0).
//
// Note what is absent and cannot be stubbed into existence: there is no
// MockDisplayKit. The kit emulates camera, captouch and permissions only.

public enum GlassesModel: Sendable { case rayBanMeta, oakleyHSTN }

public final class MockCameraService: @unchecked Sendable {
    public func setCameraFeed(fileURL: URL) {}
    public func setCapturedImage(fileURL: URL) {}
}

public final class MockServices: @unchecked Sendable {
    public let camera = MockCameraService()
}

public final class MockDevice: @unchecked Sendable {
    public let services = MockServices()
    public func powerOn() {}
    public func don() {}
}

public final class MockDeviceKit: @unchecked Sendable {
    public static let shared = MockDeviceKit()
    public func enable() {}
    public func disable() {}
    public func pairGlasses(model: GlassesModel) throws -> MockDevice { MockDevice() }
}
