import AppKit
import Carbon.HIToolbox
import PixixCodec
import PixixEngine

/// What a click on a pixel does with its color.
enum PickerAction: String, CaseIterable, Identifiable {
    /// Puts it on the clipboard in one notation.
    case copy
    /// Opens a small window that shows it in every notation.
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: "Copies the color"
        case .window: "Opens a window with its values"
        }
    }

    /// What a click with ⌥ held does instead.
    var other: PickerAction { self == .copy ? .window : .copy }
}

/// One press of the color shortcut: every display frozen under a magnifier, until a pixel is clicked or the
/// picker is dismissed.
@MainActor
final class PickerSession {
    private(set) var screens: [PickerScreenController] = []
    /// True for a scripted run, which shows nothing on screen, takes no keyboard and leaves the clipboard alone.
    let isUnattended: Bool
    /// Called once the overlays are gone. The flag says whether the app that was in front should get the keyboard back.
    var onEnd: ((_ returningFocus: Bool) -> Void)?
    /// Set when the color window asked for another color: the result goes back to it, whatever a click is set to do.
    var forcedAction: PickerAction?
    private var hasEnded = false

    init(shots: [ScreenShot], isUnattended: Bool) {
        self.isUnattended = isUnattended
        screens = shots.map { PickerScreenController(session: self, shot: $0) }
    }

    func begin() {
        for screen in screens { screen.show() }
        guard !isUnattended else { return }
        let pointer = NSEvent.mouseLocation
        let front = screens.first { $0.shot.frame.contains(pointer) } ?? screens.first
        front?.panel.makeKeyAndOrderFront(nil)
        // Only the active app chooses the pointer's shape, as for a screenshot.
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.set()
        // The magnifier is there from the start, before the pointer moves.
        front?.pointerMoved(toScreenPoint: pointer)
    }

    /// The magnifier is on one display at a time.
    func pointerCame(to screen: PickerScreenController) {
        for other in screens where other !== screen { other.pointerLeft() }
    }

    func bringForward() {
        for screen in screens { screen.panel.orderFrontRegardless() }
    }

    /// A pixel was clicked. `point` is where, in AppKit's screen coordinates.
    func finish(with color: RGBAColor, alternate: Bool, at point: NSPoint) {
        let chosen = Settings.shared.pickerAction
        let action = forcedAction ?? (alternate ? chosen.other : chosen)
        end()
        guard !isUnattended else { return }
        switch action {
        case .copy:
            let text = Settings.shared.pickerCopyNotation.text(of: color)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            CaptureOutput.announce("Copied \(text)", swatch: color)
        case .window:
            ColorWindowController.show(color, near: point)
        }
    }

    func end(returningFocus: Bool = true) {
        guard !hasEnded else { return }
        hasEnded = true
        for screen in screens { screen.close() }
        screens = []
        onEnd?(returningFocus)
    }
}

/// One display while a color is being picked: the frozen picture of it, and the magnifier that follows the
/// pointer over it.
@MainActor
final class PickerScreenController: NSObject {
    unowned let session: PickerSession
    let shot: ScreenShot
    let panel: CapturePanel
    /// The pixel the magnifier is on, counted from the top-left corner of the display. Nil while the pointer
    /// is on another display.
    private(set) var pixel: (x: Int, y: Int)?

    private let content = PickerView()
    private let picture = PickerPictureView()
    private let loupe = LoupeView()
    /// The display's pixels as plain memory, in the color space they were captured in.
    private let pixels: PixelBuffer?
    private let notations = Settings.shared.pickerNotations
    private let copied = Settings.shared.pickerCopyNotation
    /// Where the arrow keys last sent the pointer, in the view's points.
    private var nudgedTo: CGPoint?
    private var isClosed = false

    init(session: PickerSession, shot: ScreenShot) {
        self.session = session
        self.shot = shot
        panel = CapturePanel(contentRect: shot.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pixels = PixelBuffer(image: shot.image, colorSpace: Resampler.renderableColorSpace(for: shot.image))
        super.init()

        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Above the Dock and the menu bar, as the screenshot overlay is.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.cancelHandler = { [weak self] in self?.cancel() }

        content.frame = CGRect(origin: .zero, size: shot.frame.size)
        content.controller = self
        panel.contentView = content
        picture.frame = content.bounds
        picture.autoresizingMask = [.width, .height]
        picture.image = shot.image
        content.addSubview(picture)
        loupe.setFrameSize(LoupeView.size(rows: notations.count))
        loupe.isHidden = true
        content.addSubview(loupe)
    }

    // MARK: Showing and closing

    func show() {
        panel.setFrame(shot.frame, display: false)
        if session.isUnattended {
            // A scripted run draws its overlay where no screen is, as the screenshot overlay of such runs does.
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderBack(nil)
            panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        } else {
            panel.orderFrontRegardless()
        }
        panel.makeFirstResponder(content)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        content.controller = nil
        picture.image = nil
        panel.orderOut(nil)
        panel.close()
    }

    func cancel() {
        session.end()
    }

    // MARK: The pointer

    /// The pointer came onto this display: its overlay takes the keyboard.
    func pointerEntered() {
        guard !session.isUnattended, !panel.isKeyWindow else { return }
        panel.makeKey()
    }

    func pointerLeft() {
        pixel = nil
        nudgedTo = nil
        loupe.isHidden = true
    }

    /// The pointer is at a place given in AppKit's screen coordinates.
    func pointerMoved(toScreenPoint point: NSPoint) {
        pointerMoved(to: CGPoint(x: point.x - shot.frame.minX, y: shot.frame.maxY - point.y))
    }

    /// The pointer is at a place in the view: points from the top-left corner of the display.
    func pointerMoved(to point: CGPoint) {
        // The arrow keys put the pointer where it is; until it really moves, the pixel they chose stands.
        if let nudgedTo, abs(point.x - nudgedTo.x) < 1, abs(point.y - nudgedTo.y) < 1 { return }
        nudgedTo = nil
        move(toX: Int((point.x * shot.scale).rounded(.down)), y: Int((point.y * shot.scale).rounded(.down)))
    }

    private func move(toX x: Int, y: Int) {
        pixel = (min(max(x, 0), shot.image.width - 1), min(max(y, 0), shot.image.height - 1))
        session.pointerCame(to: self)
        refreshLoupe()
    }

    /// The middle of a pixel in the view's points.
    private func viewPoint(of pixel: (x: Int, y: Int)) -> CGPoint {
        CGPoint(x: (CGFloat(pixel.x) + 0.5) / shot.scale, y: (CGFloat(pixel.y) + 0.5) / shot.scale)
    }

    /// Moves by whole pixels, which a hand on a mouse cannot.
    private func nudge(dx: Int, dy: Int) {
        guard let pixel else { return }
        move(toX: pixel.x + dx, y: pixel.y + dy)
        guard let now = self.pixel else { return }
        let point = viewPoint(of: now)
        nudgedTo = point
        // The pointer goes along, so the two do not come apart. A scripted run leaves the user's pointer alone.
        guard !session.isUnattended, let main = NSScreen.screens.first else { return }
        // Core Graphics counts rows from the top of the main display.
        CGWarpMouseCursorPosition(CGPoint(x: shot.frame.minX + point.x, y: main.frame.height - shot.frame.maxY + point.y))
        // Without this the pointer stays deaf to the mouse for a quarter of a second after being moved.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: The color

    /// The color of a pixel in sRGB, which is what the notations are written in, whatever display showed it.
    func color(x: Int, y: Int) -> RGBAColor? {
        guard let pixels, let (blue, green, red, _) = pixels.pixel(x: x, y: y) else { return nil }
        let own = [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, 1]
        let converted = CGColor(colorSpace: pixels.colorSpace, components: own)?
            .converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric, options: nil)
        let parts = converted?.components.flatMap { $0.count >= 3 ? $0 : nil } ?? own
        // A color the display can show and sRGB cannot comes out past 0...1, and is held to the nearest one.
        func held(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
        return RGBAColor(red: held(parts[0]), green: held(parts[1]), blue: held(parts[2]))
    }

    /// The color under the magnifier.
    var color: RGBAColor? {
        pixel.flatMap { color(x: $0.x, y: $0.y) }
    }

    /// Where the magnifier is, in the view's points; for checking it without a person looking.
    var loupeFrame: CGRect? { loupe.isHidden ? nil : loupe.frame }

    private func refreshLoupe() {
        guard let pixel, let pixels, let color = color(x: pixel.x, y: pixel.y) else {
            loupe.isHidden = true
            return
        }
        let reach = LoupeView.cells / 2
        let around = CGRect(x: pixel.x - reach, y: pixel.y - reach, width: LoupeView.cells, height: LoupeView.cells)
        // At the edge of the display there are fewer pixels than cells.
        let part = around.intersection(pixels.bounds)
        loupe.picture = pixels.makeImage(of: part)
        loupe.pictureCells = part.offsetBy(dx: -around.minX, dy: -around.minY)
        loupe.color = color
        loupe.rows = notations.map { ($0.title, $0.value(of: color), $0 == copied) }

        // Below and to the right of the pointer; on the other side where the screen ends.
        let point = viewPoint(of: pixel)
        let size = loupe.frame.size
        let gap: CGFloat = 22, margin: CGFloat = 6
        var origin = CGPoint(x: point.x + gap, y: point.y + gap)
        if origin.x + size.width > content.bounds.maxX - margin { origin.x = point.x - gap - size.width }
        if origin.y + size.height > content.bounds.maxY - margin { origin.y = point.y - gap - size.height }
        // On a display too small for either side it stays on the screen all the same.
        origin.x = min(max(origin.x, margin), max(content.bounds.maxX - margin - size.width, margin))
        origin.y = min(max(origin.y, margin), max(content.bounds.maxY - margin - size.height, margin))
        loupe.setFrameOrigin(CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
        loupe.isHidden = false
        loupe.needsDisplay = true
    }

    // MARK: Mouse and keys

    func pick(alternate: Bool) {
        guard let pixel, let color else {
            NSSound.beep()
            return
        }
        let point = viewPoint(of: pixel)
        session.finish(with: color, alternate: alternate, at: NSPoint(x: shot.frame.minX + point.x, y: shot.frame.maxY - point.y))
    }

    /// Keys are told apart by where they are on the keyboard, so they work with any input language.
    func keyDown(_ event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Escape: cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: pick(alternate: event.modifierFlags.contains(.option))
        case kVK_LeftArrow: nudge(dx: -step, dy: 0)
        case kVK_RightArrow: nudge(dx: step, dy: 0)
        case kVK_UpArrow: nudge(dx: 0, dy: -step)
        case kVK_DownArrow: nudge(dx: 0, dy: step)
        // Every other key is swallowed: there is nothing here for it to type into.
        default: break
        }
    }

    // MARK: Diagnostics

    /// Saves a picture of the overlay with its magnifier, for checking it without a person looking.
    func writeSnapshot(to url: URL) {
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Where the mouse and the keys of a color pick arrive. Flipped, so the magnifier is placed in the same
/// top-left coordinates the pixels are counted in.
final class PickerView: NSView {
    weak var controller: PickerScreenController?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // Always, not only in the active app: the app in front may well be another one.
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func follow(_ event: NSEvent) {
        NSCursor.crosshair.set()
        controller?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.pointerEntered()
        follow(event)
    }

    override func mouseExited(with event: NSEvent) { controller?.pointerLeft() }
    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseDown(with event: NSEvent) { follow(event) }
    override func mouseDragged(with event: NSEvent) { follow(event) }

    override func mouseUp(with event: NSEvent) {
        follow(event)
        controller?.pick(alternate: event.modifierFlags.contains(.option))
    }

    /// A right click backs out.
    override func rightMouseDown(with event: NSEvent) { controller?.cancel() }

    override func keyDown(with event: NSEvent) { controller?.keyDown(event) }
}

/// The frozen picture of a display, handed to the layer as it is: nothing is drawn or copied.
final class PickerPictureView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.contentsGravity = .resize
        layer?.contents = image
    }
}

/// The magnifier beside the pointer: the pixels around it enlarged, with the one in the middle framed and its
/// color written out underneath.
final class LoupeView: NSView {
    /// Pixels across and down. Odd, so that one of them is the middle.
    static let cells = 21
    /// The side of an enlarged pixel in points.
    static let cell: CGFloat = 8
    private static let side = CGFloat(cells) * cell
    private static let band: CGFloat = 10
    private static let rowHeight: CGFloat = 19
    private static let padding: CGFloat = 7

    var picture: CGImage?
    /// Where the picture sits among the cells, in cells: it fills them all except at the edge of the display.
    var pictureCells = CGRect.zero
    var color = RGBAColor.black
    /// A line per notation; the one a click copies stands out.
    var rows: [(name: String, value: String, isCopied: Bool)] = []

    static func size(rows: Int) -> CGSize {
        CGSize(width: side, height: side + band + CGFloat(rows) * rowHeight + padding * 2)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        self.shadow = shadow
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Clicks are for the picture underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = Self.side, cell = Self.cell
        let card = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.saveGState()
        context.addPath(card)
        context.clip()
        context.setFillColor(NSColor(white: 0.13, alpha: 1).cgColor)
        context.fill(bounds)

        // Past the edge of the display there is nothing to enlarge.
        let lens = CGRect(x: 0, y: 0, width: side, height: side)
        context.setFillColor(NSColor(white: 0.06, alpha: 1).cgColor)
        context.fill(lens)
        if let picture {
            context.interpolationQuality = .none
            context.drawUpright(picture, in: CGRect(
                x: pictureCells.minX * cell, y: pictureCells.minY * cell, width: pictureCells.width * cell,
                height: pictureCells.height * cell
            ))
        }
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(0.5)
        for index in 1..<Self.cells {
            let offset = CGFloat(index) * cell
            context.move(to: CGPoint(x: offset, y: 0))
            context.addLine(to: CGPoint(x: offset, y: side))
            context.move(to: CGPoint(x: 0, y: offset))
            context.addLine(to: CGPoint(x: side, y: offset))
        }
        context.strokePath()
        // The pixel that is picked: a white frame with a dark one around it, to show on any color.
        let middle = CGFloat(Self.cells / 2) * cell
        let target = CGRect(x: middle, y: middle, width: cell, height: cell)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(1)
        context.stroke(target.insetBy(dx: -2, dy: -2))
        context.setStrokeColor(.white)
        context.setLineWidth(1.5)
        context.stroke(target.insetBy(dx: -0.75, dy: -0.75))

        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: side, width: side, height: Self.band))
        context.restoreGState()

        var y = side + Self.band + Self.padding
        for row in rows {
            let ink = NSColor.white.withAlphaComponent(row.isCopied ? 1 : 0.72)
            let name = NSAttributedString(string: row.name, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: ink.withAlphaComponent(ink.alphaComponent * 0.6),
            ])
            let value = NSAttributedString(string: row.value, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: row.isCopied ? .semibold : .regular), .foregroundColor: ink,
            ])
            name.draw(at: CGPoint(x: 10, y: y + (Self.rowHeight - name.size().height) / 2 + 0.5))
            value.draw(at: CGPoint(x: 40, y: y + (Self.rowHeight - value.size().height) / 2))
            y += Self.rowHeight
        }

        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 11.5, cornerHeight: 11.5, transform: nil))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }
}
