import AppKit

@main
struct OverlayTests {
    static func main() {
        for visible in [NSRect(x: 0, y: 25, width: 1440, height: 850),
                        NSRect(x: -1920, y: -200, width: 1920, height: 1050),
                        NSRect(x: 100, y: 100, width: 200, height: 70)] {
            precondition(visible.contains(overlayFrame(in: visible)))
        }
        _ = NSApplication.shared
        let overlay = FloatingOverlayController()
        overlay.showRecording()
        overlay.setLevel(.infinity)
        overlay.showTranscribing()
        overlay.showThinking(text: "question")
        overlay.showSuccess(response: "answer")
        let panel = NSApp.windows.first { $0 is NSPanel && $0.isVisible }!
        precondition(panel.screen!.visibleFrame.contains(panel.frame))
        let buttons = panel.contentView!.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }
        var opened = false
        overlay.onOpenChat = { opened = true }
        buttons.first { $0.title == "Open Chat" }!.performClick(nil)
        precondition(opened && !panel.isVisible)
        overlay.showError("error")
        var closed = false
        overlay.onClose = { closed = true }
        buttons.first { $0.accessibilityLabel() == "Close" }!.performClick(nil)
        precondition(closed && !panel.isVisible)
        print("Voice overlay tests passed.")
    }
}
