import AppKit

final class LogPanelController: NSWindowController {
    private let textView = NSTextView()
    private var storage = ""
    private let maxCharacters = 80_000

    convenience init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "运行日志"
        window.minSize = NSSize(width: 480, height: 240)
        window.isFloatingPanel = false
        window.level = .normal
        window.setFrameAutosaveName("DSHLogPanel")
        self.init(window: window)
        setupContent()
    }

    func append(_ chunk: String) {
        storage.append(chunk)
        if storage.count > maxCharacters {
            storage = String(storage.suffix(maxCharacters * 4 / 5))
        }
        textView.string = storage
        textView.scrollToEndOfDocument(nil)
    }

    func reset() {
        storage = ""
        textView.string = ""
    }

    func toggle(relativeTo parent: NSWindow?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
            return
        }
        show(relativeTo: parent)
    }

    func show(relativeTo parent: NSWindow?) {
        if let parent, let panel = window, !panel.isVisible {
            var frame = panel.frame
            let parentFrame = parent.frame
            frame.origin.x = parentFrame.maxX - frame.width - 24
            frame.origin.y = parentFrame.minY + 24
            panel.setFrame(frame, display: false)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func setupContent() {
        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 10, height: 8)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        window?.contentView = scroll
    }
}
