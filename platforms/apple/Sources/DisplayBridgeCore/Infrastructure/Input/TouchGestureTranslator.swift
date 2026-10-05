import CoreGraphics

/// Turns raw touches on a sink's screen into the pointer events a source understands.
///
/// One finger taps and drags with the primary button, two fingers scroll, and a
/// two-finger tap is a secondary click. A finger's press is held back until it either
/// moves or lifts, so the first finger of a two-finger scroll never clicks whatever is
/// under it. A pen presses immediately and reports its pressure.
///
/// Platform-neutral on purpose (the same rules as the Android client's
/// `DisplaySurfaceView`): the UIKit view only feeds it touch positions.
public struct TouchGestureTranslator {
    public enum Phase { case began, moved, ended, cancelled }

    /// How far a finger may wander and still count as a tap, in view points.
    public var slop: CGFloat = 10

    private var down = CGPoint.zero
    private var pressed = false      // a Down has been sent and not yet released
    private var scrolling = false    // a two-finger gesture is in progress
    private var scrollMoved = false  // ...and it moved far enough to be a scroll, not a tap
    private var scrollStart = CGPoint.zero
    private var lastScroll = CGPoint.zero

    public init() {}

    /// - Parameters:
    ///   - points: the touches taking part in this update, in view points relative to the
    ///     picture's top-left corner. For `.ended` that is the lifted touch first.
    ///   - remaining: how many touches are still on the screen after this update.
    ///   - size: the size of the picture in view points.
    ///   - precise: true for a pen, which presses immediately.
    public mutating func handle(
        _ phase: Phase, points: [CGPoint], remaining: Int, in size: CGSize,
        precise: Bool = false, pressure: Float = 1
    ) -> [InputEvent] {
        guard let first = points.first, size.width > 0, size.height > 0 else { return [] }
        func event(_ kind: InputEvent.Kind, _ p: CGPoint, button: UInt8 = 0, dx: CGFloat = 0, dy: CGFloat = 0, pressure: Float = 1) -> InputEvent {
            InputEvent(
                kind: kind, button: button,
                x: Float(min(max(p.x / size.width, 0), 1)), y: Float(min(max(p.y / size.height, 0), 1)),
                dx: Float(dx / size.width), dy: Float(dy / size.height), pressure: pressure
            )
        }
        func centre() -> CGPoint {
            CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        }

        switch phase {
        case .began:
            if remaining >= 2, points.count >= 2 {
                // A second finger landed: this is a scroll (or a two-finger tap).
                var events: [InputEvent] = []
                if pressed {
                    events.append(event(.up, first, pressure: 0))
                    pressed = false
                }
                scrolling = true
                scrollMoved = false
                scrollStart = centre()
                lastScroll = scrollStart
                return events
            }
            down = first
            scrolling = false
            scrollMoved = false
            if precise {
                pressed = true
                return [event(.down, first, pressure: pressure)]
            }
            // Hold the press back; just bring the pointer here for now.
            pressed = false
            return [event(.hover, first, pressure: 0)]

        case .moved:
            if scrolling {
                guard points.count >= 2 else { return [] }
                let now = centre()
                defer { lastScroll = now }
                if scrollMoved || hypot(now.x - scrollStart.x, now.y - scrollStart.y) > slop {
                    scrollMoved = true
                    return [event(.scroll, down, dx: now.x - lastScroll.x, dy: now.y - lastScroll.y, pressure: 0)]
                }
                return []
            }
            if pressed {
                return [event(.move, first, pressure: pressure)]
            }
            if hypot(first.x - down.x, first.y - down.y) > slop {
                // The finger travelled: this is a drag, starting where it landed.
                pressed = true
                return [event(.down, down), event(.move, first)]
            }
            return []

        case .ended:
            guard remaining == 0 else { return [] }
            defer { pressed = false; scrolling = false }
            if scrolling {
                // Two fingers down and up without travelling: a secondary click.
                return scrollMoved ? [] : [event(.down, down, button: 1), event(.up, down, button: 1, pressure: 0)]
            }
            if pressed {
                return [event(.up, first, pressure: 0)]
            }
            return [event(.down, down), event(.up, down, pressure: 0)]

        case .cancelled:
            defer { pressed = false; scrolling = false }
            return pressed ? [event(.up, first, pressure: 0)] : []
        }
    }
}
