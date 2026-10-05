import Foundation

/// A pointer event a sink sends back to its source. Mirrors the Rust `InputEvent`:
/// positions are 0..1 across the shared display, scroll deltas are fractions of its size.
public struct InputEvent: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case down = 0
        case move = 1
        case up = 2
        case scroll = 3
        case hover = 4
    }

    public var kind: Kind
    /// 0 primary, 1 secondary.
    public var button: UInt8
    public var x: Float
    public var y: Float
    public var dx: Float
    public var dy: Float
    /// 0..1; 1.0 for a plain touch or click.
    public var pressure: Float

    public init(kind: Kind, button: UInt8 = 0, x: Float, y: Float, dx: Float = 0, dy: Float = 0, pressure: Float = 1) {
        self.kind = kind
        self.button = button
        self.x = x
        self.y = y
        self.dx = dx
        self.dy = dy
        self.pressure = pressure
    }
}
