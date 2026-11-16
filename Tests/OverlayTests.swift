import AppKit

@main
struct OverlayTests {
    static func main() {
        for visible in [NSRect(x: 0, y: 25, width: 1440, height: 850),
                        NSRect(x: -1920, y: -200, width: 1920, height: 1050),
                        NSRect(x: 100, y: 100, width: 200, height: 70)] {
            let frame = overlayFrame(in: visible)
            precondition(visible.contains(frame))
            precondition(frame.width <= 340 && frame.height <= 66)
        }
        _ = NSApplication.shared
        let overlay = FloatingOverlayController()
        overlay.showError(String(repeating: "unbroken", count: 10000))
        guard let panel = NSApplication.shared.windows.first(where: { $0 is NSPanel && $0.isVisible }),
              let screen = panel.screen else { fatalError("Missing overlay") }
        panel.contentView?.layoutSubtreeIfNeeded()
        precondition(screen.visibleFrame.contains(panel.frame))
        precondition(panel.frame.width == min(480, screen.visibleFrame.width) && panel.frame.height == min(360, screen.visibleFrame.height))
        overlay.showSuccess(text: "hello", response: "world")
        panel.contentView?.layoutSubtreeIfNeeded()
        precondition(screen.visibleFrame.contains(panel.frame))
        precondition(panel.frame.width == min(480, screen.visibleFrame.width))
        precondition(panel.frame.height == min(360, screen.visibleFrame.height))
        guard let scroll = panel.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
              let response = scroll.documentView as? NSTextView else { fatalError("Missing response view") }
        precondition(!scroll.isHidden && response.isSelectable && !response.isEditable)
        precondition(response.string == "You: hello\n\nAssistant: world")
        guard let input = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
              let send = panel.contentView?.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Send" }) else { fatalError("Missing composer") }
        var sends = 0
        overlay.onSendText = { _ in sends += 1; return false }
        input.stringValue = "hello"
        send.performClick(nil)
        precondition(sends == 1 && input.stringValue == "hello")
        overlay.onSendText = { _ in sends += 1; return true }
        send.performClick(nil)
        send.performClick(nil)
        precondition(sends == 2 && input.stringValue.isEmpty)
        let userStyle = response.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let assistantStyle = response.textStorage?.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle
        precondition(userStyle?.headIndent == 74 && assistantStyle?.headIndent == 14)
        guard let mic = panel.contentView?.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "Start recording" }),
              let countdown = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "Auto-close paused" }) else { fatalError("Missing response controls") }
        precondition(countdown.stringValue == "Auto-close paused")
        precondition(mic.image != nil && !mic.isBordered && mic.toolTip == "Start recording")
        precondition(mic.image!.size.width <= 16 && mic.image!.size.height <= 16)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearance)
            panel.contentView?.layoutSubtreeIfNeeded()
            precondition(panel.contentView!.bounds.contains(mic.frame))
            precondition(panel.contentView!.bounds.contains(send.frame))
            precondition(panel.contentView!.bounds.contains(input.frame))
            precondition(scroll.frame.minY >= mic.frame.maxY)
            precondition(input.frame.maxX <= send.frame.minX && send.frame.maxX <= mic.frame.minX)
        }
        // Exercise actual AppKit layout and rendering, not just the constraint declarations.
        let originalFrame = panel.frame
        for width: CGFloat in [200, 280, 480] {
            panel.setContentSize(NSSize(width: width, height: 360))
            panel.contentView!.layoutSubtreeIfNeeded()
            precondition(abs(mic.frame.width - 40) < 0.01 && abs(mic.frame.height - 40) < 0.01)
            precondition(input.frame.width >= 0 && input.frame.maxX <= send.frame.minX && send.frame.maxX <= mic.frame.minX)
            precondition(panel.contentView!.bounds.contains(mic.frame))
            guard let bitmap = panel.contentView!.bitmapImageRepForCachingDisplay(in: panel.contentView!.bounds) else { fatalError("No bitmap") }
            panel.contentView!.cacheDisplay(in: panel.contentView!.bounds, to: bitmap)
            if width == 480, let path = ProcessInfo.processInfo.environment["OVERLAY_SNAPSHOT"],
               let png = bitmap.representation(using: .png, properties: [:]) {
                try! png.write(to: URL(fileURLWithPath: path))
            }
            print("Composer width \(width): input \(input.frame), send \(send.frame), mic \(mic.frame)")
        }
        panel.setFrame(originalFrame, display: true)
        var microphonePresses = 0
        overlay.onMicrophone = { microphonePresses += 1 }
        mic.performClick(nil)
        precondition(microphonePresses == 1)
        overlay.showSuccess(text: "again", response: "second", history: "You: hello\nAssistant: world\n\nYou: again\nAssistant: second")
        precondition(response.string.contains("You: hello\nAssistant: world") && response.string.contains("You: again\nAssistant: second"))
        overlay.showRecording()
        precondition(!mic.isHidden && mic.accessibilityLabel() == "Stop recording")
        precondition(mic.image != nil && mic.toolTip == "Stop recording")
        precondition(!scroll.isHidden && response.string.contains("Voice message · Recording"))
        precondition(panel.frame.height == min(360, screen.visibleFrame.height))
        overlay.showTranscribing()
        precondition(response.string.contains("Voice message · Transcribing"))
        overlay.showThinking(text: "spoken words")
        precondition(response.string.contains("spoken words") && response.string.contains("Thinking"))

        var closes = 0
        overlay.onClose = { closes += 1 }
        let stages: [() -> Void] = [
            { overlay.showRecording() }, { overlay.showTranscribing() },
            { overlay.showThinking(text: "hello") },
            { overlay.showSuccess(text: "hello", response: "world") },
            { overlay.showError("error") }
        ]
        for show in stages {
            show()
            precondition(panel.isVisible && screen.visibleFrame.contains(panel.frame))
            guard let button = panel.contentView?.subviews.first(where: { $0.accessibilityLabel() == "Close" }) else { fatalError("Missing close button") }
            precondition(!button.isHidden && button.accessibilityPerformPress())
            precondition(!panel.isVisible)
        }
        precondition(closes == stages.count)
        overlay.showRecording(); overlay.hide()
        precondition(closes == stages.count)
        var automaticCloses = 0
        let timed = FloatingOverlayController(dismissalInterval: 0.1)
        timed.onClose = { closes += 1 }
        timed.onAutoClose = { automaticCloses += 1 }
        timed.showSuccess(text: "test", response: "answer")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(automaticCloses == 1 && closes == stages.count)
        timed.showSuccess(text: "test", response: "answer")
        timed.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(automaticCloses == 1)
        print("Overlay tests passed.")
    }
}
