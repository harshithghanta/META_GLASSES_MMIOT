import Foundation

// Stubs for MWDATCore, transcribed from the REAL DAT 0.8.0 public interface:
//   facebook/meta-wearables-dat-ios @ 0.8.0
//   MWDATCore.xcframework/ios-arm64/.../arm64-apple-ios.swiftinterface
// Only the symbols the app uses are mirrored, with the real names, types,
// optionality and typed-throws clauses. Error enums keep only a placeholder
// case where the app never matches on cases. Bodies are fakes.
//
// If you upgrade the SDK, re-diff these against the new .swiftinterface.

public protocol DatError: LocalizedError {}

public enum WearablesError: Int, DatError { case notConfigured }
public enum RegistrationError: Int, DatError { case failed }
public enum UnregistrationError: Int, DatError { case failed }
public enum WearablesHandleURLError: Int, DatError { case invalidURL }
public enum PermissionError: Int, DatError { case denied }

@frozen public enum DeviceSessionError: DatError, Equatable {
    case noEligibleDevice
    case sessionAlreadyStopped
    case sessionAlreadyExists
    case sessionIdle
    case capabilityAlreadyActive
    case capabilityNotFound
    case unexpectedError(description: String)
}

public enum Permission: Sendable, CaseIterable { case camera }
public enum PermissionStatus: Sendable { case granted, denied }

@frozen public enum DeviceSessionState: Equatable, Sendable {
    case idle, starting, started, paused, stopping, stopped
}

/// Real: `public protocol AnyListenerToken: Sendable { func cancel() async }`
public protocol AnyListenerToken: Sendable {
    func cancel() async
}

/// Real: `public protocol Announcer<T>` — a protocol, used as `any Announcer<T>`.
public protocol Announcer<T> {
    associatedtype T: Sendable
    func listen(_ listener: @escaping @Sendable (Self.T) -> Void) -> any AnyListenerToken
}

// Fakes used only to give the stub getters something to return.
public struct StubListenerToken: AnyListenerToken { public init() {}; public func cancel() async {} }
public struct StubAnnouncer<T: Sendable>: Announcer {
    public init() {}
    public func listen(_ listener: @escaping @Sendable (T) -> Void) -> any AnyListenerToken { StubListenerToken() }
}

public typealias DeviceIdentifier = String

public final class Device: Sendable {}
public typealias DeviceFilter = @Sendable (Device) -> Bool

public protocol DeviceSelector: Sendable {}

public final class AutoDeviceSelector: DeviceSelector {
    public init(wearables: any WearablesInterface, filter: DeviceFilter? = nil) {}
}

public final class DeviceSession: Sendable {
    public init() {}
    public let deviceId: DeviceIdentifier = ""
    public var statePublisher: any Announcer<DeviceSessionState> { StubAnnouncer<DeviceSessionState>() }
    public var state: DeviceSessionState { .started }
    public func start() throws(DeviceSessionError) {}
    public func stop() {}
    public func stateStream() -> AsyncStream<DeviceSessionState> {
        AsyncStream { $0.yield(.started); $0.finish() }
    }
    // NOTE: the real 0.8.0 DeviceSession has NO removeStream()/removeDisplay().
}

public protocol WearablesInterface: Sendable {
    func startRegistration() async throws(RegistrationError)
    func handleUrl(_ url: URL) async throws(WearablesHandleURLError) -> Bool
    func startUnregistration() async throws(UnregistrationError)
    func checkPermissionStatus(_ permission: Permission) async throws(PermissionError) -> PermissionStatus
    func requestPermission(_ permission: Permission) async throws(PermissionError) -> PermissionStatus
    func createSession(deviceSelector: any DeviceSelector) throws(DeviceSessionError) -> DeviceSession
}

public enum Wearables {
    public static func configure() throws(WearablesError) {}
    public static var shared: any WearablesInterface { StubWearables() }
}

final class StubWearables: WearablesInterface {
    func startRegistration() async throws(RegistrationError) {}
    func handleUrl(_ url: URL) async throws(WearablesHandleURLError) -> Bool { true }
    func startUnregistration() async throws(UnregistrationError) {}
    func checkPermissionStatus(_ permission: Permission) async throws(PermissionError) -> PermissionStatus { .granted }
    func requestPermission(_ permission: Permission) async throws(PermissionError) -> PermissionStatus { .granted }
    func createSession(deviceSelector: any DeviceSelector) throws(DeviceSessionError) -> DeviceSession { DeviceSession() }
}
