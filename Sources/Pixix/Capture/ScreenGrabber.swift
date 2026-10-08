import AppKit
import ScreenCaptureKit

/// One display as it looked when the shortcut was pressed.
struct ScreenShot {
    /// The display in AppKit's screen coordinates, in points.
    let frame: CGRect
    let image: CGImage
    /// The windows that were on this display, front to back, in image pixels with a top-left origin.
    var windows: [CGRect] = []

    /// Image pixels per point.
    var scale: CGFloat { CGFloat(image.width) / max(frame.width, 1) }
}

enum CaptureError: LocalizedError {
    case noImage, timedOut

    var errorDescription: String? {
        switch self {
        case .noImage: "macOS returned no picture of the screen."
        case .timedOut: "macOS did not return a picture of the screen in time."
        }
    }
}

/// Lets the first of several answers through and drops the rest.
private final class OneAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var isGiven = false

    /// True for the caller that gets to answer.
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isGiven { return false }
        isGiven = true
        return true
    }
}

/// Takes pictures of the displays. Needs the Screen Recording permission.
enum ScreenGrabber {
    /// Whether macOS lets this app see the screen. Asks nothing.
    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Makes macOS ask for the permission, the first time. After a refusal it asks nothing and returns false.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Every display at its full resolution, without the pointer.
    @MainActor
    static func grab() async throws -> [ScreenShot] {
        struct Target: Sendable {
            let frame: CGRect
            /// The display in Core Graphics' global coordinates: points, counted from the top of the main display.
            let bounds: CGRect
            let scale: CGFloat
        }
        let targets = NSScreen.screens.compactMap { screen -> Target? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Target(frame: screen.frame, bounds: CGDisplayBounds(number.uint32Value), scale: screen.backingScaleFactor)
        }
        let windows = windowFrames()
        let images = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask { (index, try await capture(target.bounds, scale: target.scale)) }
            }
            var result: [Int: CGImage] = [:]
            for try await (index, image) in group { result[index] = image }
            return result
        }
        return targets.enumerated().compactMap { index, target in
            guard let image = images[index] else { return nil }
            var shot = ScreenShot(frame: target.frame, image: image)
            let scale = shot.scale
            let pixels = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            shot.windows = windows.compactMap { window in
                let local = CGRect(
                    x: (window.minX - target.bounds.minX) * scale, y: (window.minY - target.bounds.minY) * scale,
                    width: window.width * scale, height: window.height * scale
                ).intersection(pixels).integral
                return local.width >= 40 && local.height >= 40 ? local : nil
            }
            return shot
        }
    }

    private static func capture(_ rect: CGRect, scale: CGFloat) async throws -> CGImage {
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        // The picture goes back onto the same display, so it should be made for it.
        configuration.displayIntent = .local
        configuration.width = Int((rect.width * scale).rounded())
        configuration.height = Int((rect.height * scale).rounded())
        return try await withCheckedThrowingContinuation { continuation in
            // Without a limit, a capture that macOS never answers would leave the shortcut dead until a restart.
            let answer = OneAnswer()
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                if answer.take() { continuation.resume(throwing: CaptureError.timedOut) }
            }
            SCScreenshotManager.captureScreenshot(rect: rect, configuration: configuration) { output, error in
                if let image = output?.sdrImage {
                    if answer.take() { continuation.resume(returning: image) }
                    return
                }
                // The older call takes no settings, so the pointer may be in the picture, but it is a picture.
                SCScreenshotManager.captureImage(in: rect) { image, olderError in
                    guard answer.take() else { return }
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? olderError ?? CaptureError.noImage)
                    }
                }
            }
        }
    }

    /// Where the ordinary windows are, front to back, in Core Graphics' global coordinates.
    /// Their positions are public knowledge; only their names and contents need the permission.
    private static func windowFrames() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0, info[kCGWindowAlpha as String] as? Double ?? 1 > 0.05,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return rect
        }
    }
}
