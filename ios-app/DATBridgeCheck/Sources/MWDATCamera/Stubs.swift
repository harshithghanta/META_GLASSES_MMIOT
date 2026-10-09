import Foundation
import MWDATCore

// Stubs for MWDATCamera, transcribed from the REAL DAT 0.8.0 .swiftinterface.
// Key facts the real API encodes: there is no one-shot photo API;
// `capturePhoto` returns Bool (false when no stream is running) and the photo
// arrives on `photoDataPublisher`. `Stream` has NO `stateStream()` — observe
// `state` / `statePublisher` instead.

public enum CaptureError: DatError, Equatable { case photo_capture_timeout, photo_capture_failed }

public enum VideoCodec: Sendable { case raw, hvc1 }
public enum StreamingResolution: Sendable, CaseIterable { case high, medium, low }
public enum PhotoCaptureFormat: Sendable { case heic, jpeg }

@frozen public enum StreamState: Sendable {
    case stopping, stopped, waitingForDevice, starting, streaming, paused
}

public struct StreamConfiguration: Sendable {
    public let videoCodec: VideoCodec
    public let resolution: StreamingResolution
    public let frameRate: UInt
    public init(videoCodec: VideoCodec, resolution: StreamingResolution, frameRate: UInt) {
        self.videoCodec = videoCodec; self.resolution = resolution; self.frameRate = frameRate
    }
    public init() { self.init(videoCodec: .raw, resolution: .low, frameRate: 24) }
}

public struct PhotoData: Sendable {
    public let data: Data
    public let format: PhotoCaptureFormat
    public init(data: Data, format: PhotoCaptureFormat) { self.data = data; self.format = format }
}

public final class Stream: Sendable {
    public let streamConfiguration: StreamConfiguration
    init(config: StreamConfiguration) { streamConfiguration = config }
    public var state: StreamState { .streaming }
    public var statePublisher: any Announcer<StreamState> { StubAnnouncer<StreamState>() }
    public var photoDataPublisher: any Announcer<PhotoData> { StubAnnouncer<PhotoData>() }
    public func start() {}
    public func stop() {}
    @discardableResult
    public func capturePhoto(format: PhotoCaptureFormat) -> Bool { true }
}

public extension DeviceSession {
    func addStream(config: StreamConfiguration = StreamConfiguration()) throws(DeviceSessionError) -> Stream? {
        Stream(config: config)
    }
}
