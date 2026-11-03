import CoreGraphics
import Foundation

/// The arithmetic of a rectangular frame pulled by its corners and edges, optionally held to fixed proportions.
/// Shared by the crop tool and the screenshot selection. A ratio is width divided by height.
public enum FrameGeometry {
    /// Where the eight handles sit: 0...3 are the corners clockwise from top-left, 4...7 the edges from the top.
    public static func handlePoints(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
        ]
    }

    /// A frame from a fixed corner to the pointer, forced into the proportions when there are any.
    /// With `bounds` the frame never leaves them: it stops growing where it meets an edge.
    public static func frame(anchor: CGPoint, to point: CGPoint, ratio: CGFloat?, within bounds: CGRect? = nil) -> CGRect {
        var point = point
        if let bounds {
            point.x = min(max(point.x, bounds.minX), bounds.maxX)
            point.y = min(max(point.y, bounds.minY), bounds.maxY)
        }
        var width = abs(point.x - anchor.x), height = abs(point.y - anchor.y)
        if let ratio {
            if width / max(height, 0.0001) > ratio { height = width / ratio } else { width = height * ratio }
            if let bounds {
                let roomX = point.x < anchor.x ? anchor.x - bounds.minX : bounds.maxX - anchor.x
                let roomY = point.y < anchor.y ? anchor.y - bounds.minY : bounds.maxY - anchor.y
                let fit = min(1, roomX / max(width, 0.0001), roomY / max(height, 0.0001))
                width *= fit
                height *= fit
            }
        }
        return CGRect(
            x: point.x < anchor.x ? anchor.x - width : anchor.x, y: point.y < anchor.y ? anchor.y - height : anchor.y,
            width: width, height: height
        )
    }

    /// The frame after one of its edges (0 top, 1 right, 2 bottom, 3 left) was dragged to the pointer.
    /// With proportions, the other dimension grows evenly on both sides.
    public static func frame(
        _ original: CGRect, draggingEdge edge: Int, to point: CGPoint, ratio: CGFloat?, within bounds: CGRect? = nil
    ) -> CGRect {
        var point = point
        if let bounds {
            point.x = min(max(point.x, bounds.minX), bounds.maxX)
            point.y = min(max(point.y, bounds.minY), bounds.maxY)
        }
        var result = original
        switch edge {
        case 0:
            result.origin.y = min(point.y, original.maxY - 1)
            result.size.height = original.maxY - result.minY
        case 1:
            result.size.width = max(point.x - original.minX, 1)
        case 2:
            result.size.height = max(point.y - original.minY, 1)
        default:
            result.origin.x = min(point.x, original.maxX - 1)
            result.size.width = original.maxX - result.minX
        }
        guard let ratio else { return result }
        if edge % 2 == 0 {
            var height = result.height, width = height * ratio
            if let bounds {
                let room = 2 * min(original.midX - bounds.minX, bounds.maxX - original.midX)
                if width > room {
                    width = max(room, 1)
                    height = width / ratio
                }
            }
            return CGRect(
                x: original.midX - width / 2, y: edge == 0 ? original.maxY - height : original.minY, width: width, height: height
            )
        }
        var width = result.width, height = width / ratio
        if let bounds {
            let room = 2 * min(original.midY - bounds.minY, bounds.maxY - original.midY)
            if height > room {
                height = max(room, 1)
                width = height * ratio
            }
        }
        return CGRect(
            x: edge == 3 ? original.maxX - width : original.minX, y: original.midY - height / 2, width: width, height: height
        )
    }

    /// The frame after handle `index` (numbered as in `handlePoints`) was taken to `point`:
    /// a corner moves against the opposite one, an edge against the opposite edge.
    public static func frame(_ original: CGRect, draggingHandle index: Int, to point: CGPoint, ratio: CGFloat?) -> CGRect {
        guard index < 4 else { return frame(original, draggingEdge: index - 4, to: point, ratio: ratio) }
        return frame(anchor: handlePoints(original)[(index + 2) % 4], to: point, ratio: ratio)
    }

    /// The point pulled onto the edge of `bounds` when it lies just outside it, no further than `distance`.
    /// Inside the bounds nothing is pulled, so an edge can be set one pixel in from the border; the pull only
    /// catches a frame that overshoots the picture.
    public static func snapped(_ point: CGPoint, outsideOf bounds: CGRect, within distance: CGFloat) -> CGPoint {
        CGPoint(
            x: snapped(point.x, outsideOf: bounds.minX, bounds.maxX, within: distance),
            y: snapped(point.y, outsideOf: bounds.minY, bounds.maxY, within: distance)
        )
    }

    /// A frame being moved, slid onto the edges of `bounds` it overshoots by no more than `distance`.
    public static func snapped(_ rect: CGRect, outsideOf bounds: CGRect, within distance: CGFloat) -> CGRect {
        var result = rect
        if rect.minX < bounds.minX, rect.minX >= bounds.minX - distance { result.origin.x = bounds.minX }
        if rect.maxX > bounds.maxX, rect.maxX <= bounds.maxX + distance { result.origin.x = bounds.maxX - rect.width }
        if rect.minY < bounds.minY, rect.minY >= bounds.minY - distance { result.origin.y = bounds.minY }
        if rect.maxY > bounds.maxY, rect.maxY <= bounds.maxY + distance { result.origin.y = bounds.maxY - rect.height }
        return result
    }

    private static func snapped(_ value: CGFloat, outsideOf low: CGFloat, _ high: CGFloat, within distance: CGFloat) -> CGFloat {
        if value < low, value >= low - distance { return low }
        if value > high, value <= high + distance { return high }
        return value
    }

    /// The frame shrunk about its center until it has the proportions.
    public static func fitted(_ rect: CGRect, ratio: CGFloat) -> CGRect {
        guard rect.width > 0, rect.height > 0, ratio > 0 else { return rect }
        var size = rect.size
        if size.width / size.height > ratio {
            size.width = size.height * ratio
        } else {
            size.height = size.width / ratio
        }
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The frame slid back inside the bounds, and cut down to them where it is larger.
    public static func moved(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(rect.width, bounds.width)
        result.size.height = min(rect.height, bounds.height)
        result.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    /// The frame given an exact size, keeping its top-left corner where the bounds allow it.
    public static func sized(_ rect: CGRect, to size: CGSize, within bounds: CGRect) -> CGRect {
        moved(CGRect(origin: rect.origin, size: CGSize(width: max(size.width, 1), height: max(size.height, 1))), into: bounds)
    }
}
