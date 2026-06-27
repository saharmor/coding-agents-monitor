import SwiftUI

@main
struct UsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var panel: FloatingPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--install-bridge-only") {
            store.installBridgeOnlyAndExit()
            return
        }

        NSApp.setActivationPolicy(.accessory)
        LoginItemInstaller.installForCurrentApp()
        store.start()

        let panel = FloatingPanelController(contentView: WidgetView(store: store))
        self.panel = panel
        panel.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
