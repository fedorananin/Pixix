import AppKit

/// A round translucent button that floats over the image.
final class FloatingButton: NSControl {
    private let imageView = NSImageView()
    private var isPressed = false { didSet { updateBackground() } }
    private var isHovered = false { didSet { updateBackground() } }

    init(symbol: String, pointSize: CGFloat = 17, diameter: CGFloat = 44, toolTip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        self.toolTip = toolTip

        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(configuration)
        imageView.contentTintColor = .white
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateBackground()
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        ))
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateBackground() {
        let alpha: CGFloat = isPressed ? 0.8 : (isHovered ? 0.65 : 0.45)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
        return true
    }
}

/// The zoom pill at the bottom of the window.
final class ZoomBar: NSView {
    let zoomOut = ZoomBar.button("minus", "Zoom Out")
    let zoomIn = ZoomBar.button("plus", "Zoom In")
    let fit = ZoomBar.button("arrow.down.right.and.arrow.up.left", "Fit to Window")
    let actual = ZoomBar.button("1.magnifyingglass", "Actual Size")
    let playPause = ZoomBar.button("pause.fill", "Pause")
    private let label = NSTextField(labelWithString: "100%")
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        layer?.cornerRadius = 18

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.widthAnchor.constraint(equalToConstant: 48).isActive = true

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [playPause, zoomOut, label, zoomIn, fit, actual] as [NSView] {
            stack.addArrangedSubview(view)
        }
        playPause.isHidden = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ toolTip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))!
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = toolTip
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    func setZoom(percent: Int) {
        label.stringValue = "\(percent)%"
    }

    func setPlayback(visible: Bool, playing: Bool) {
        playPause.isHidden = !visible
        let symbol = playing ? "pause.fill" : "play.fill"
        playPause.image = NSImage(systemSymbolName: symbol, accessibilityDescription: playing ? "Pause" : "Play")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        playPause.toolTip = playing ? "Pause" : "Play"
    }
}

/// Centered message for the empty window and for files that fail to open.
final class MessageView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        detail.lineBreakMode = .byWordWrapping
        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(symbol: String, title: String, detail: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 44, weight: .light))
        self.title.stringValue = title
        self.detail.stringValue = detail
        isHidden = false
    }
}
