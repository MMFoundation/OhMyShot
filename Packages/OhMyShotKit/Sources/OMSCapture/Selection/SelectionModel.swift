import CoreGraphics

/// The rectangle being dragged out, kept within its bounds (one display, or every display when a
/// drag may cross from one to another) and on the pixel grid.
///
/// Coordinates are AppKit global points. Edges snap to framebuffer pixels (the sharpest display's,
/// across displays), so a selection always captures whole pixels and its reported size is exact.
public struct SelectionModel: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Keep the selection to its shape (Shift): a square, unless `shape` says another.
        public static let square = Modifiers(rawValue: 1 << 0)
        /// Grow from the starting point in every direction (Option).
        public static let fromCenter = Modifiers(rawValue: 1 << 1)
        /// Leave the edges where the pointer puts them, not snapped to text (Command): for the rest of the drag
        /// once it has been held, since letting go of it would otherwise throw the edges to the text.
        public static let unsnapped = Modifiers(rawValue: 1 << 2)
    }

    public struct DisplayBounds: Equatable, Sendable {
        public let frame: CGRect
        public let pixelsPerPoint: CGFloat

        public init(frame: CGRect, pixelsPerPoint: CGFloat) {
            self.frame = frame
            self.pixelsPerPoint = max(pixelsPerPoint, 1)
        }
    }

    /// The display's frame, or the box around every display; the selection never leaves it.
    public let bounds: CGRect
    private let basePixelsPerPoint: CGFloat
    /// Individual display frames and pixel densities when spanning multiple displays; empty for single-bounds usage.
    public let displays: [DisplayBounds]
    /// The active framebuffer scale for the current selection (the sharpest display intersected by `rect`, or the
    /// display under `anchor`/`pointer`, falling back to the initializer scale).
    public var pixelsPerPoint: CGFloat {
        scale(for: rect, fallbackPoint: anchor ?? pointer)
    }
    /// The shape `.square` keeps, width over height; 1, a square, unless set.
    public var shape: CGFloat = 1

    public private(set) var anchor: CGPoint?
    public private(set) var rect: CGRect?
    /// The point the selection was last dragged to, as the pointer gave it.
    public private(set) var pointer: CGPoint?
    /// How far the arrow keys have moved the dragged corner from the pointer. The corner stays that far from it
    /// for the rest of the drag, so a nudge is not thrown away by the pointer's next move.
    public private(set) var cornerOffset = CGVector.zero
    /// The edges of `rect` that snapped to text, for the overlay to mark.
    public private(set) var snappedEdges: TextSnap.Edges = []
    /// Unsnapped was asked for during this drag: its edges stay where the pointer puts them until the next one.
    private var placedFreely = false

    public init(bounds: CGRect, pixelsPerPoint: CGFloat, displays: [DisplayBounds] = []) {
        self.bounds = bounds
        self.basePixelsPerPoint = max(pixelsPerPoint, 1)
        self.displays = displays
    }

    public mutating func begin(at point: CGPoint) {
        anchor = snapped(clamped(point))
        rect = nil
        pointer = point
        cornerOffset = .zero
        snappedEdges = []
        placedFreely = false
    }

    /// Drags the selection out to `point`. With `snapping`, edges near the blocks of text it knows move to
    /// them; a selection kept square or grown from the center, one that has been dragged with `.unsnapped`
    /// since it began, and one still too small to be a drag have their shape set by the pointer alone.
    public mutating func drag(to point: CGPoint, modifiers: Modifiers = [], snapping: TextSnap? = nil) {
        guard let anchor else { return }
        pointer = point
        let current = corner(of: point)
        var dx = current.x - anchor.x
        var dy = current.y - anchor.y
        if modifiers.contains(.square) {
            // The longer side leads. The shape holds at the edges: it shrinks to fit there, never cut to a
            // different one. A side not dragged at all grows toward the room there is.
            var roomX = max(0, dx < 0 ? anchor.x - bounds.minX : bounds.maxX - anchor.x)
            var roomY = max(0, dy < 0 ? anchor.y - bounds.minY : bounds.maxY - anchor.y)
            var signX: CGFloat = dx < 0 ? -1 : 1, signY: CGFloat = dy < 0 ? -1 : 1
            if dx == 0, roomX == 0 { signX = -1; roomX = max(0, anchor.x - bounds.minX) }
            if dy == 0, roomY == 0 { signY = -1; roomY = max(0, anchor.y - bounds.minY) }
            if modifiers.contains(.fromCenter) {
                roomX = max(0, min(anchor.x - bounds.minX, bounds.maxX - anchor.x))
                roomY = max(0, min(anchor.y - bounds.minY, bounds.maxY - anchor.y))
            }
            let shape = shape > 0 ? shape : 1
            let width = min(max(abs(dx), abs(dy) * shape), roomX, roomY * shape)
            dx = width * signX
            dy = width / shape * signY
        }
        var next: CGRect
        if modifiers.contains(.fromCenter) {
            next = CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        } else {
            next = CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy), width: abs(dx), height: abs(dy))
        }
        snappedEdges = []
        if modifiers.contains(.unsnapped) { placedFreely = true }
        // A click with a hair of jitter is not a drag to snap: it must stay a click, as it is without snapping.
        if let snapping, !placedFreely, modifiers.isDisjoint(with: [.square, .fromCenter]), !Self.isClick(pixels(of: snapped(next))) {
            let result = snapping.snapped(next, within: bounds)
            next = result.rect
            snappedEdges = result.edges
        }
        next = next.intersection(bounds)
        rect = next.isNull ? nil : snapped(next)
        if rect == nil { snappedEdges = [] }
    }

    /// Moves the dragged corner by `delta` while the pointer stays where it is, as the arrow keys do, and draws the
    /// selection again. The corner stops at the bounds; a pointer beyond them leaves the corner at the edge, which
    /// the keys then move from. A nudge the selection does not show (the shape held across it, or the room ran out)
    /// is not kept, so no hidden distance builds up for a later release of Shift to bring out. Once nudged, the
    /// selection no longer snaps to text for the rest of the drag.
    ///
    /// A selection whose edges snapped to text is nudged from where the snap put them, not from the pointer: the
    /// edges stay where they were, and only the dragged corner moves, by the key's distance.
    public mutating func nudge(by delta: CGVector, modifiers: Modifiers = []) {
        guard let anchor, let pointer else { return }
        let before = self
        let base = clamped(pointer)
        var current = corner(of: pointer)
        let fromSnap = rect != nil && !snappedEdges.isEmpty
        if let rect, fromSnap {
            // The snap moved the anchor's edges as well as the pointer's: the selection as shown is the one to go on from.
            let right = current.x >= anchor.x, up = current.y >= anchor.y
            self.anchor = CGPoint(x: right ? rect.minX : rect.maxX, y: up ? rect.minY : rect.maxY)
            current = CGPoint(x: right ? rect.maxX : rect.minX, y: up ? rect.maxY : rect.minY)
        }
        let target = clamped(CGPoint(x: current.x + delta.dx, y: current.y + delta.dy))
        cornerOffset = CGVector(dx: target.x - base.x, dy: target.y - base.y)
        drag(to: pointer, modifiers: modifiers)
        if before.rect != nil, rect == before.rect {
            self = before
            return
        }
        // Set to the pixel by hand: snapping to text would undo it at the pointer's next move.
        if isNudged || fromSnap { placedFreely = true }
    }

    /// Whether the arrow keys have moved the dragged corner off the pointer.
    public var isNudged: Bool {
        cornerOffset != .zero
    }

    /// The point the selection is being dragged to: the pointer, and with the arrow keys the corner they moved.
    public var corner: CGPoint? {
        pointer.map(corner(of:))
    }

    /// Where the selection's dragged corner is for a pointer at `point`: the pointer, kept in the bounds, and the
    /// arrow keys' offset from there, kept in them too.
    private func corner(of point: CGPoint) -> CGPoint {
        let base = clamped(point)
        return clamped(CGPoint(x: base.x + cornerOffset.dx, y: base.y + cornerOffset.dy))
    }

    /// Moves the whole selection, as when Space is held during a drag. It stops at the display edges.
    public mutating func move(by delta: CGVector) {
        guard let rect else { return }
        var moved = rect.offsetBy(dx: delta.dx, dy: delta.dy)
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        if displays.count > 1 {
            let xSpan = displays.filter { $0.frame.maxX > moved.minX && $0.frame.minX < moved.maxX }
            if !xSpan.isEmpty {
                let minY = xSpan.map(\.frame.minY).max() ?? bounds.minY
                let maxY = xSpan.map(\.frame.maxY).min() ?? bounds.maxY
                if maxY - minY >= moved.height {
                    moved.origin.y = min(max(moved.minY, minY), maxY - moved.height)
                } else {
                    let unionMinY = xSpan.map(\.frame.minY).min() ?? bounds.minY
                    let unionMaxY = xSpan.map(\.frame.maxY).max() ?? bounds.maxY
                    moved.origin.y = min(max(moved.minY, unionMinY), max(unionMinY, unionMaxY - moved.height))
                }
            }
            let ySpan = displays.filter { $0.frame.maxY > moved.minY && $0.frame.minY < moved.maxY }
            if !ySpan.isEmpty {
                let minX = ySpan.map(\.frame.minX).max() ?? bounds.minX
                let maxX = ySpan.map(\.frame.maxX).min() ?? bounds.maxX
                if maxX - minX >= moved.width {
                    moved.origin.x = min(max(moved.minX, minX), maxX - moved.width)
                } else {
                    let unionMinX = ySpan.map(\.frame.minX).min() ?? bounds.minX
                    let unionMaxX = ySpan.map(\.frame.maxX).max() ?? bounds.maxX
                    moved.origin.x = min(max(moved.minX, unionMinX), max(unionMinX, unionMaxX - moved.width))
                }
            }
        }
        self.rect = snapped(moved)
        snappedEdges = []
        anchor = anchor.map { CGPoint(x: $0.x + (moved.minX - rect.minX), y: $0.y + (moved.minY - rect.minY)) }
        // The pointer is moving the selection along with it: the dragged corner follows both.
        pointer = pointer.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
    }

    public mutating func reset() {
        anchor = nil
        rect = nil
        pointer = nil
        cornerOffset = .zero
        snappedEdges = []
    }

    /// The selection's size in framebuffer pixels, which is exactly the captured image's size.
    public var pixelSize: (width: Int, height: Int) {
        guard let rect else { return (0, 0) }
        return pixels(of: rect)
    }

    /// Too small to be a deliberate selection (a click, not a drag).
    public var isTooSmall: Bool {
        Self.isClick(pixelSize)
    }

    private func scale(for rect: CGRect?, fallbackPoint: CGPoint? = nil) -> CGFloat {
        guard !displays.isEmpty else { return basePixelsPerPoint }
        if let rect, !rect.isNull, !rect.isEmpty {
            let hit = displays.filter { !$0.frame.intersection(rect).isEmpty }
            if let maxScale = hit.map(\.pixelsPerPoint).max() { return maxScale }
        }
        if let point = fallbackPoint, let display = displays.first(where: { $0.frame.contains(point) }) {
            return display.pixelsPerPoint
        }
        return basePixelsPerPoint
    }

    private func pixels(of rect: CGRect) -> (width: Int, height: Int) {
        let s = scale(for: rect, fallbackPoint: anchor ?? pointer)
        return (Int((rect.width * s).rounded()), Int((rect.height * s).rounded()))
    }

    private static func isClick(_ size: (width: Int, height: Int)) -> Bool {
        size.width < 4 || size.height < 4
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        if displays.count > 1 {
            if displays.contains(where: { $0.frame.contains(point) }) { return point }
            var best = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
            var bestDist = CGFloat.greatestFiniteMagnitude
            for d in displays {
                let candidate = CGPoint(x: min(max(point.x, d.frame.minX), d.frame.maxX), y: min(max(point.y, d.frame.minY), d.frame.maxY))
                let dx = candidate.x - point.x, dy = candidate.y - point.y
                let dist = dx * dx + dy * dy
                if dist < bestDist {
                    bestDist = dist
                    best = candidate
                }
            }
            return best
        }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func snapped(_ point: CGPoint) -> CGPoint {
        let s = scale(for: nil, fallbackPoint: point)
        return CGPoint(x: snap(point.x, origin: bounds.minX, scale: s), y: snap(point.y, origin: bounds.minY, scale: s))
    }

    private func snapped(_ rect: CGRect) -> CGRect {
        let s = scale(for: rect, fallbackPoint: anchor ?? pointer)
        let minX = snap(rect.minX, origin: bounds.minX, scale: s), maxX = snap(rect.maxX, origin: bounds.minX, scale: s)
        let minY = snap(rect.minY, origin: bounds.minY, scale: s), maxY = snap(rect.maxY, origin: bounds.minY, scale: s)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func snap(_ value: CGFloat, origin: CGFloat, scale: CGFloat) -> CGFloat {
        origin + ((value - origin) * scale).rounded() / scale
    }
}
