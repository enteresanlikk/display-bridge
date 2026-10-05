import CoreGraphics
import Foundation

/// Turns a sink's pointer events into real macOS mouse events on the display that sink
/// is showing, so touching the tablet clicks what is under the finger.
///
/// Posting events needs the Accessibility permission (System Settings > Privacy &
/// Security > Accessibility); without it `CGEvent.post` is silently dropped.
public final class InputInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var displayID: CGDirectDisplayID
    // Synthetic events don't get a click count from the system, so double-click has to
    // be tracked here: a second press close in time and space bumps the count.
    private var lastDownTime: CFAbsoluteTime = 0
    private var lastDownPoint: CGPoint = .zero
    private var clickCount: Int64 = 1

    /// A fingertip double-tap lands far less precisely than a mouse double-click.
    private static let multiClickRadius: CGFloat = 16
    private static let multiClickInterval: CFAbsoluteTime = 0.5

    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    /// Whether this process may post events, prompting the user once if it may not.
    @discardableResult
    public static func requestAccess() -> Bool {
        CGPreflightPostEventAccess() || CGRequestPostEventAccess()
    }

    public func updateDisplayID(_ id: CGDirectDisplayID) {
        lock.withLock { displayID = id }
    }

    /// Maps a normalized position onto `bounds` (global display coordinates), keeping
    /// it inside so `x == 1` can't spill onto the neighbouring display.
    static func point(x: Float, y: Float, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(bounds.minX + CGFloat(x) * bounds.width, bounds.maxX - 1),
            y: min(bounds.minY + CGFloat(y) * bounds.height, bounds.maxY - 1)
        )
    }

    public func inject(_ event: InputEvent) {
        lock.lock()
        defer { lock.unlock() }

        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else { return }
        let point = Self.point(x: event.x, y: event.y, in: bounds)

        if event.kind == .scroll {
            // Scroll targets whatever is under the cursor, so park the cursor there first.
            post(.mouseMoved, at: point, button: .left)
            // Content follows the finger: dragging down/right scrolls up/left.
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(CGFloat(event.dy) * bounds.height),
                wheel2: Int32(CGFloat(event.dx) * bounds.width),
                wheel3: 0
            )?.post(tap: .cghidEventTap)
            return
        }

        let secondary = event.button == 1
        let button: CGMouseButton = secondary ? .right : .left
        let type: CGEventType
        switch event.kind {
        case .down:
            let now = CFAbsoluteTimeGetCurrent()
            let near = hypot(point.x - lastDownPoint.x, point.y - lastDownPoint.y) <= Self.multiClickRadius
            clickCount = (near && now - lastDownTime <= Self.multiClickInterval) ? clickCount + 1 : 1
            lastDownTime = now
            lastDownPoint = point
            type = secondary ? .rightMouseDown : .leftMouseDown
        case .move:
            type = secondary ? .rightMouseDragged : .leftMouseDragged
        case .up:
            type = secondary ? .rightMouseUp : .leftMouseUp
        case .hover, .scroll:
            type = .mouseMoved
        }
        post(type, at: point, button: button, pressure: event.kind == .up ? 0 : Double(event.pressure))
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, pressure: Double = 0) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        if type != .mouseMoved {
            e.setIntegerValueField(.mouseEventClickState, value: clickCount)
            e.setDoubleValueField(.mouseEventPressure, value: pressure)
        }
        e.post(tap: .cghidEventTap)
    }
}
