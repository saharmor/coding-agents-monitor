import AppKit
import SwiftUI

extension Notification.Name {
    static let usageMonitorWeeklyVisibilityChanged = Notification.Name("usageMonitorWeeklyVisibilityChanged")
    static let usageMonitorCollapsedChanged = Notification.Name("usageMonitorCollapsedChanged")
    static let usageMonitorSnoozeRequested = Notification.Name("usageMonitorSnoozeRequested")
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let defaultsKey = "floatingPanelFrame"
    private let collapsedDefaultsKey = "usageWidgetCollapsed"
    private let snoozeUntilDefaultsKey = "usageWidgetSnoozeUntil"
    private let collapsedSize = NSSize(width: 160, height: 42)
    private let compactSize = NSSize(width: 220, height: 112)
    private let weeklySize = NSSize(width: 220, height: 158)
    private let cornerRadius: CGFloat = 12
    private let snoozeDuration: TimeInterval = 60 * 60
    private var isCollapsed: Bool
    private var showsWeekly = false
    private var snoozeTimer: Timer?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(snoozeRequested),
            name: .usageMonitorSnoozeRequested,
            object: nil
        )
    }

    func show() {
        if scheduleActiveSnoozeIfNeeded() {
            return
        }
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

    @objc private func snoozeRequested() {
        let until = Date().addingTimeInterval(snoozeDuration)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: snoozeUntilDefaultsKey)
        window.orderOut(nil)
        scheduleSnoozeTimer(until: until)
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

    private func scheduleActiveSnoozeIfNeeded() -> Bool {
        guard let until = activeSnoozeUntil() else {
            return false
        }
        scheduleSnoozeTimer(until: until)
        return true
    }

    private func activeSnoozeUntil() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: snoozeUntilDefaultsKey)
        guard timestamp > 0 else {
            return nil
        }

        let until = Date(timeIntervalSince1970: timestamp)
        if until > Date() {
            return until
        }

        UserDefaults.standard.removeObject(forKey: snoozeUntilDefaultsKey)
        return nil
    }

    private func scheduleSnoozeTimer(until: Date) {
        snoozeTimer?.invalidate()
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.finishSnooze()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        snoozeTimer = timer
    }

    private func finishSnooze() {
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        UserDefaults.standard.removeObject(forKey: snoozeUntilDefaultsKey)
        window.orderFrontRegardless()
    }

    deinit {
        MainActor.assumeIsolated {
            snoozeTimer?.invalidate()
        }
        NotificationCenter.default.removeObserver(self)
    }
}
