import Foundation
import ActivityAssistantCore
import MWDATCore
import MWDATDisplay

// NOTE: this file deliberately does **not** import SwiftUI.
// MWDATDisplay exports its own `Text` and `Button` view builders. Importing
// SwiftUI here would make every `Text(...)` below ambiguous. All SwiftUI lives
// in Views/; all glasses rendering lives here.

/// Turns a `DisplayFrame` — the core package's device-independent description
/// of what the wearer should see — into a Device Access Toolkit view tree.
///
/// Written against **DAT 0.8.0**. Two constraints from the display docs shape
/// everything here:
///
///   * `display.send` replaces the **whole screen** every time. There is no
///     partial update, so each state emits one complete tree.
///   * The render target is **600 × 600** and the panel dims at 20 s idle,
///     sleeping at 25 s. Sleep does not end the session, so we simply re-send
///     the current frame on wake rather than tearing anything down.
enum GlassesDisplayRenderer {

    /// Build the tree for one frame.
    ///
    /// Layout is a single column: headline, optional detail, then the actions.
    /// The HUD only scrolls vertically and has no horizontal layout worth
    /// using at this size, so a column is the whole design.
    static func tree(for frame: DisplayFrame) -> FlexBox {
        FlexBox(direction: .column, spacing: 12) {
            Text(frame.headline, style: .heading)

            if let detail = frame.detail {
                Text(detail, style: .body, color: .secondary)
            }

            // Tone is conveyed with an icon rather than colour: the waveguide
            // is additive and monochrome-ish, so a hue change reads far more
            // weakly than a distinct glyph.
            if let icon = iconName(for: frame.tone) {
                Icon(name: icon, style: .filled)
            }

            for action in frame.actions {
                Button(
                    label: action.title,
                    style: buttonStyle(for: action.id),
                    iconName: iconName(for: action.id)
                ) {
                    IntentBus.shared.send(action.id)
                }
            }
        }
    }

    private static func iconName(for tone: DisplayFrame.Tone) -> IconName? {
        switch tone {
        case .neutral:  nil                      // Ready needs no ornament.
        case .working:  nil                      // The stage text already says it.
        case .success:  .checkmarkCircle
        case .caution:  .exclamationmarkTriangle
        case .failure:  .exclamationmarkCircle
        }
    }

    private static func buttonStyle(for intent: DisplayFrame.Intent) -> ButtonStyle {
        switch intent {
        case .analyze, .tryAgain: .primary
        case .dismiss:            .secondary
        }
    }

    private static func iconName(for intent: DisplayFrame.Intent) -> IconName? {
        switch intent {
        case .analyze:  .arrowRight
        case .tryAgain: .arrowClockwise
        case .dismiss:  .xmark
        }
    }
}

/// Carries taps from the glasses back to the engine.
///
/// DAT delivers button taps as plain closures with no context and no
/// guaranteed thread, so we need one well-known place to funnel them. This is
/// a lock-protected class rather than an actor because `send` is called from
/// inside a synchronous DAT callback and `intents()` has to satisfy a
/// non-async protocol requirement — an actor would force `await` on both.
final class IntentBus: @unchecked Sendable {
    static let shared = IntentBus()

    private let lock = NSLock()
    private var continuation: AsyncStream<DisplayFrame.Intent>.Continuation?

    func stream() -> AsyncStream<DisplayFrame.Intent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DisplayFrame.Intent.self)
        lock.lock()
        self.continuation?.finish()   // replace any previous subscriber
        self.continuation = continuation
        lock.unlock()
        return stream
    }

    func send(_ intent: DisplayFrame.Intent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(intent)
    }

    func finish() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }
}
