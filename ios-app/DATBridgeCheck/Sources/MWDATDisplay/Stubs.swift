import Foundation
import MWDATCore

// Stubs for MWDATDisplay, transcribed from the REAL DAT 0.8.0 .swiftinterface.
// `IconName` lists only a subset of the real cases, but every case here exists
// in the real enum (real names: `.exclamationTriangle`, not
// `.exclamationmarkTriangle`; `.twoArrowsClockwise`; `.x`).

public enum DisplayError: DatError, Equatable { case deviceNotFound, connectionNotAvailable, deviceDisconnected }
@frozen public enum DisplayState: Equatable, Hashable, Sendable { case starting, started, stopping, stopped }

public enum TextStyle: Sendable { case heading, body, meta }
public enum TextColor: Sendable { case primary, secondary }
public enum ButtonStyle: Sendable { case primary, secondary, outline }
public enum IconStyle: Sendable { case filled, outline }
public enum Direction: Sendable { case column, row, columnReverse, rowReverse }
public enum Alignment: Sendable { case start, center, end, stretch }

public enum IconName: String, Sendable {
    case arrowLeft, arrowRight, checkmark, checkmarkCircle
    case exclamationCircle, exclamationTriangle, twoArrowsClockwise, x, gear, bell
}

public struct EdgeInsets: Sendable {
    public init(top: CGFloat = 0, bottom: CGFloat = 0, leading: CGFloat = 0, trailing: CGFloat = 0) {}
    public init(all value: CGFloat) {}
}

public protocol DisplayableView: Sendable {}
public protocol ViewComponent: Sendable {}

public struct Text: Sendable {
    public init(_ content: String, style: TextStyle = .body, color: TextColor = .primary) {}
}
public struct Icon: Sendable {
    public init(name: IconName, style: IconStyle = .filled) {}
}
public struct Button: Sendable {
    public init(label: String, style: ButtonStyle = .primary, iconName: IconName? = nil,
                onClick: (@Sendable () -> Void)? = nil) {}
}

/// Real: `@_functionBuilder public struct ComponentBuilder` with exactly these
/// builder methods (note: no buildExpression for arrays).
@resultBuilder
public struct ComponentBuilder {
    public static func buildBlock(_ components: [any ViewComponent]...) -> [any ViewComponent] { components.flatMap { $0 } }
    public static func buildArray(_ components: [[any ViewComponent]]) -> [any ViewComponent] { components.flatMap { $0 } }
    public static func buildOptional(_ component: [any ViewComponent]?) -> [any ViewComponent] { component ?? [] }
    public static func buildEither(first component: [any ViewComponent]) -> [any ViewComponent] { component }
    public static func buildEither(second component: [any ViewComponent]) -> [any ViewComponent] { component }
    public static func buildExpression(_ expression: any ViewComponent) -> [any ViewComponent] { [expression] }
}

public struct FlexBox: Sendable {
    public init(direction: Direction = .column, spacing: CGFloat = 0, alignment: Alignment = .start,
                crossAlignment: Alignment = .start, wrap: Bool = false, padding: EdgeInsets? = nil,
                @ComponentBuilder content: () -> [any ViewComponent]) {}
}

extension Button: ViewComponent {}
extension FlexBox: ViewComponent {}
extension FlexBox: DisplayableView {}
extension Icon: ViewComponent {}
extension Text: ViewComponent {}

public final class Display: Sendable {
    init() {}
    public var statePublisher: any Announcer<DisplayState> { StubAnnouncer<DisplayState>() }
    public var state: DisplayState { .started }
    public func start() {}
    public func stop() {}
    public func send(_ view: some DisplayableView) async throws {}
    public func clearDisplay() async throws {}
}

public extension DeviceSession {
    func addDisplay() throws(DeviceSessionError) -> Display { Display() }
}
