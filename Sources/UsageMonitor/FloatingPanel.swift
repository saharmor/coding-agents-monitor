import AppKit
import SwiftUI

extension Notification.Name {
    static let usageMonitorWeeklyVisibilityChanged = Notification.Name("usageMonitorWeeklyVisibilityChanged")
    static let usageMonitorCollapsedChanged = Notification.Name("usageMonitorCollapsedChanged")
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let defaultsKey = "floatingPanelFrame"
    private let collapsedDefaultsKey = "usageWidgetCollapsed"
    private let collapsedSize = NSSize(width: 160, height: 42)
    private let compactSize = NSSize(width: 220, height: 112)
    private let weeklySize = NSSize(width: 220, height: 158)
    private let cornerRadius: CGFloat = 12
    private var isCollapsed: Bool
    private var showsWeekly = false

    init(contentView: WidgetView) {
        isCollapsed = UserDefaults.standard.bool(forKey: collapsedDefaultsKey)
        let initialSize = isCollapsed ? collapsedSize : compactSize
        let defaultFrame = NSRect(x: 80, y: 620, width: initialSize.width, height: initialSize.height)
        window = NSPanel(
            contentRect: defaultFrame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: defaultFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = cornerRadius
        hostingView.layer?.masksToBounds = true

        window.delegate = self
        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.titleVisibility = .hidden

        if let frame = UserDefaults.standard.string(forKey: defaultsKey) {
            let saved = NSRectFromString(frame)
            let restoredFrame = NSRect(
                x: saved.minX,
                y: saved.maxY - initialSize.height,
                width: initialSize.width,
                height: initialSize.height
            )
            window.setFrame(restoredFrame, display: false)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(weeklyVisibilityChanged(_:)),
            name: .usageMonitorWeeklyVisibilityChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(collapsedChanged(_:)),
            name: .usageMonitorCollapsedChanged,
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
        showsWeekly = notification.userInfo?["showsWeekly"] as? Bool ?? false
        guard !isCollapsed else {
            return
        }
        setPanelSize(sizeForCurrentState())
    }

    @objc private func collapsedChanged(_ notification: Notification) {
        isCollapsed = notification.userInfo?["isCollapsed"] as? Bool ?? false
        setPanelSize(sizeForCurrentState())
    }

    private func sizeForCurrentState() -> NSSize {
        if isCollapsed {
            return collapsedSize
        }
        return showsWeekly ? weeklySize : compactSize
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
        window.contentView?.frame = NSRect(origin: .zero, size: size)
        UserDefaults.standard.set(NSStringFromRect(resizedFrame), forKey: defaultsKey)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
