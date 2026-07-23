import Foundation

// Shape-only stubs for MWDATCore, written from Meta's published DAT 0.8.0 API
// reference. Bodies are empty; only the signatures matter, because the point is
// to type-check the bridge, not to simulate glasses.

public enum WearablesError: Error { case notConfigured }
public enum DeviceSessionError: Error { case unavailable }
public enum PermissionError: Error { case denied }

public enum Permission: Sendable { case camera, microphone, speech }
public enum PermissionStatus: Sendable { case granted, denied, undetermined }

public enum DeviceSessionState: Sendable { case starting, started, stopping, stopped }

/// Token returned by every `listen` call. The real SDK requires you to retain
/// it or the listener is torn down.
public final class AnyListenerToken: Sendable {
    public init() {}
}

/// Publisher shape used throughout the iOS SDK.
public struct Announcer<Value: Sendable>: Sendable {
    public init() {}
    @discardableResult
    public func listen(_ handler: @escaping @Sendable (Value) -> Void) -> AnyListenerToken {
        AnyListenerToken()
    }
}

public protocol DeviceSelector: Sendable {}

public struct AutoDeviceSelector: DeviceSelector {
    public init(wearables: WearablesInterface) {}
}

public final class DeviceSession: @unchecked Sendable {
    public init() {}
    public var statePublisher: Announcer<DeviceSessionState> { Announcer() }
    public func stateStream() -> AsyncStream<DeviceSessionState> {
        AsyncStream { $0.yield(.started); $0.finish() }
    }
    public func start() throws {}
    public func stop() {}
    public func removeStream() {}
    public func removeDisplay() {}
}

public protocol WearablesInterface: AnyObject, Sendable {
    func startRegistration() throws
    func startUnregistration() throws
    func handleUrl(_ url: URL) async throws -> Bool
    func checkPermissionStatus(_ permission: Permission) async throws -> PermissionStatus
    func requestPermission(_ permission: Permission) async throws -> PermissionStatus
    func createSession(deviceSelector: any DeviceSelector) throws -> DeviceSession
}

public enum Wearables {
    public static func configure() throws {}
    public static let shared: WearablesInterface = StubWearables()
}

final class StubWearables: WearablesInterface, @unchecked Sendable {
    func startRegistration() throws {}
    func startUnregistration() throws {}
    func handleUrl(_ url: URL) async throws -> Bool { true }
    func checkPermissionStatus(_ permission: Permission) async throws -> PermissionStatus { .granted }
    func requestPermission(_ permission: Permission) async throws -> PermissionStatus { .granted }
    func createSession(deviceSelector: any DeviceSelector) throws -> DeviceSession { DeviceSession() }
}
