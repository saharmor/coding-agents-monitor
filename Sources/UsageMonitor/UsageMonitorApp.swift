import SwiftUI
import UsageCore

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
        if CommandLine.arguments.contains("--check-codex-usage") {
            diagnosticReader = CodexAccountReader()
            diagnosticReader?.read { result in
                switch result {
                case .success(let snapshot):
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .secondsSince1970
                    if let data = try? encoder.encode(snapshot) {
                        print(String(decoding: data, as: UTF8.self))
                    }
                    exit(0)
                case .failure(let error):
                    print(error.localizedDescription)
                    exit(1)
                }
            }
            return
        }
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
        false
    }

    private var diagnosticReader: CodexAccountReader?

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}
