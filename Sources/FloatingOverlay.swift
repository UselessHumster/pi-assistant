import AppKit

/// Keep the indicator inside the usable area, including displays with negative origins.
func overlayFrame(in visible: NSRect) -> NSRect {
    let width = min(390, max(0, visible.width))
    let height = min(72, max(0, visible.height))
    return NSRect(x: visible.midX - width / 2, y: max(visible.minY, visible.maxY - height - 24), width: width, height: height)
}

/// A non-activating voice indicator. Only ChatWindow owns conversation UI.
final class FloatingOverlayController: NSObject {
    var onOpenChat: (() -> Void)?
    var onClose: (() -> Void)?

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let meter = NSProgressIndicator()
    private lazy var open = NSButton(title: "Open Chat", target: self, action: #selector(openChat))
    private lazy var close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: self, action: #selector(closePressed))

    override init() {
        super.init()
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .hudWindow; background.state = .active; background.blendingMode = .behindWindow
        background.wantsLayer = true; background.layer?.cornerRadius = 14; background.layer?.masksToBounds = true
        panel.contentView = background

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = NSStackView(views: [title, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        meter.isIndeterminate = false; meter.minValue = 0; meter.maxValue = 1; meter.controlSize = .small
        close.isBordered = false; close.setAccessibilityLabel("Close")
        let row = NSStackView(views: [icon, labels, meter, open, close]); row.spacing = 10; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            meter.widthAnchor.constraint(equalToConstant: 56),
            close.widthAnchor.constraint(equalToConstant: 24)
        ])
    }

    func showRecording(toggle: Bool = false) {
        setLevel(0)
        update("Recording", detail: toggle ? "Press shortcut again to send" : "Release shortcut to send", symbol: "mic.fill", recording: true)
    }

    func setLevel(_ level: Float) { meter.doubleValue = level.isFinite ? Double(max(0, min(1, level))) : 0 }
    func showTranscribing() { update("Transcribing", detail: "Converting speech to text…", symbol: "waveform") }
    func showSuccess(response: String) { update("Response ready", detail: response, symbol: "checkmark.circle.fill", canOpen: true) }
    func showError(_ message: String) { update("Error", detail: message, symbol: "exclamationmark.triangle.fill", canOpen: true) }
    func hide() { panel.orderOut(nil) }

    private func update(_ title: String, detail: String, symbol: String, recording: Bool = false, canOpen: Bool = false) {
        self.title.stringValue = title
        self.detail.stringValue = detail.replacingOccurrences(of: "\n", with: " ")
        self.detail.toolTip = detail
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        meter.isHidden = !recording; open.isHidden = !canOpen
        if let screen = (panel.isVisible ? panel.screen : nil) ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrame(overlayFrame(in: screen.visibleFrame), display: true)
        }
        panel.orderFrontRegardless()
    }

    @objc private func closePressed() { hide(); onClose?() }
    @objc private func openChat() { hide(); onOpenChat?() }
}
