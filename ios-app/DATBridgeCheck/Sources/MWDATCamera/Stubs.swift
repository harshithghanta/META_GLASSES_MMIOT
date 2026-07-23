import Foundation
import MWDATCore

// Shape-only stubs for MWDATCamera (DAT 0.8.0).
//
// The one architectural fact these encode: there is no one-shot photo API.
// `capturePhoto` is fire-and-forget and only valid while a stream is running;
// the result arrives on `photoDataPublisher`.

public enum StreamError: Error { case unavailable }
public enum CaptureError: Error { case failed }

public enum VideoCodec: Sendable { case raw, h264, h265 }
public enum StreamResolution: Sendable { case low, medium, high }
public enum PhotoCaptureFormat: Sendable { case jpeg, heic }

public enum StreamState: Sendable {
    case stopping, stopped, waitingForDevice, starting, streaming, paused
}

public struct StreamConfiguration: Sendable {
    public init(videoCodec: VideoCodec = .raw,
                resolution: StreamResolution = .low,
                frameRate: Int = 24) {}
}

public struct PhotoData: Sendable {
    public let data: Data
    public init(data: Data) { self.data = data }
}

public struct VideoFrame: Sendable {
    public init() {}
}

public final class Stream: @unchecked Sendable {
    public init() {}
    public var statePublisher: Announcer<StreamState> { Announcer() }
    public var photoDataPublisher: Announcer<PhotoData> { Announcer() }
    public var videoFramePublisher: Announcer<VideoFrame> { Announcer() }
    public func stateStream() -> AsyncStream<StreamState> {
        AsyncStream { $0.yield(.streaming); $0.finish() }
    }
    public func start() {}
    public func stop() {}
    public func capturePhoto(format: PhotoCaptureFormat) {}
}

public extension DeviceSession {
    func addStream(config: StreamConfiguration = StreamConfiguration()) throws -> Stream {
        Stream()
    }
}
