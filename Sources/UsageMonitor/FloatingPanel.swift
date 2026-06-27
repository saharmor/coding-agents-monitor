import AppKit
import SwiftUI

extension Notification.Name {
    static let usageMonitorWeeklyVisibilityChanged = Notification.Name("usageMonitorWeeklyVisibilityChanged")
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let defaultsKey = "floatingPanelFrame"
    private let compactSize = NSSize(width: 220, height: 112)
    private let weeklySize = NSSize(width: 220, height: 158)

    init(contentView: WidgetView) {
        let defaultFrame = NSRect(x: 80, y: 620, width: compactSize.width, height: compactSize.height)
        window = NSPanel(
            contentRect: defaultFrame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.delegate = self
        window.contentView = NSHostingView(rootView: contentView)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.titleVisibility = .hidden

        if let frame = UserDefaults.standard.string(forKey: defaultsKey) {
            let saved = NSRectFromString(frame)
            let compactFrame = NSRect(
                x: saved.minX,
                y: saved.maxY - compactSize.height,
                width: compactSize.width,
                height: compactSize.height
            )
            window.setFrame(compactFrame, display: false)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(weeklyVisibilityChanged(_:)),
            name: .usageMonitorWeeklyVisibilityChanged,
            object: nil
        )
    }

    func show() {
        window.orderFrontRegardless()
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: defaultsKey)
    }

    @objc private func weeklyVisibilityChanged(_ notification: Notification) {
        let showsWeekly = notification.userInfo?["showsWeekly"] as? Bool ?? false
        setPanelSize(showsWeekly ? weeklySize : compactSize)
    }

    private func setPanelSize(_ size: NSSize) {
        let frame = window.frame
        let resizedFrame = NSRect(
            x: frame.minX,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        window.setFrame(resizedFrame, display: true, animate: true)
        UserDefaults.standard.set(NSStringFromRect(resizedFrame), forKey: defaultsKey)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
