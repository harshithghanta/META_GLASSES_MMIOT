import Foundation
import MWDATCore

// Shape-only stubs for MWDATDisplay (DAT 0.8.0).
//
// Primitive inventory is deliberately exactly the documented one — FlexBox,
// Text, Image, Button, Icon, VideoPlayer — so the renderer cannot accidentally
// depend on a component the real panel does not have.

public enum DisplayError: Error { case unavailable }
public enum DisplayState: Sendable { case starting, started, stopping, stopped, closed }

public enum TextStyle: Sendable { case heading, body, meta }
public enum TextColor: Sendable { case primary, secondary }
public enum ButtonStyle: Sendable { case primary, secondary, outline }
public enum IconStyle: Sendable { case filled, outline }
public enum Direction: Sendable { case column, row, columnReverse, rowReverse }

public enum IconName: Sendable {
    case checkmarkCircle, exclamationmarkTriangle, exclamationmarkCircle
    case arrowRight, arrowLeft, arrowClockwise, xmark, gear, bell
}

public protocol DisplayView: Sendable {}

public struct Text: DisplayView {
    public init(_ text: String, style: TextStyle = .body, color: TextColor = .primary) {}
}

public struct Icon: DisplayView {
    public init(name: IconName, style: IconStyle = .filled) {}
}

public struct Button: DisplayView {
    public init(label: String,
                style: ButtonStyle = .primary,
                iconName: IconName? = nil,
                action: @escaping @Sendable () -> Void) {}
}

@resultBuilder
public enum DisplayViewBuilder {
    public static func buildBlock(_ parts: any DisplayView...) -> [any DisplayView] { parts }
    public static func buildOptional(_ part: [any DisplayView]?) -> [any DisplayView] { part ?? [] }
    public static func buildEither(first: [any DisplayView]) -> [any DisplayView] { first }
    public static func buildEither(second: [any DisplayView]) -> [any DisplayView] { second }
    public static func buildArray(_ parts: [[any DisplayView]]) -> [any DisplayView] { parts.flatMap { $0 } }
    public static func buildExpression(_ expression: any DisplayView) -> [any DisplayView] { [expression] }
    public static func buildExpression(_ expression: [any DisplayView]) -> [any DisplayView] { expression }
    public static func buildBlock(_ parts: [any DisplayView]...) -> [any DisplayView] { parts.flatMap { $0 } }
}

public struct FlexBox: DisplayView {
    public init(direction: Direction = .column,
                spacing: Int = 0,
                @DisplayViewBuilder content: () -> [any DisplayView]) {}
}

public final class Display: @unchecked Sendable {
    public init() {}
    public var statePublisher: Announcer<DisplayState> { Announcer() }
    public func stateStream() -> AsyncStream<DisplayState> {
        AsyncStream { $0.yield(.started); $0.finish() }
    }
    public func start() {}
    public func stop() {}
    @discardableResult
    public func send(_ content: any DisplayView) async throws -> Bool { true }
}

public extension DeviceSession {
    func addDisplay() throws -> Display { Display() }
}
