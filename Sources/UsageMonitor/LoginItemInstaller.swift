import Foundation

enum LoginItemInstaller {
    private static let label = "com.saharmor.coding-agents-monitor"

    static func installForCurrentApp() {
        guard let appURL = currentAppBundleURL() else {
            return
        }

        do {
            let launchAgents = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)

            let plistURL = launchAgents.appendingPathComponent("\(label).plist")
            let payload = try plistData(appURL: appURL)

            if let existing = try? Data(contentsOf: plistURL), existing == payload {
                return
            }

            let temporary = plistURL.deletingLastPathComponent()
                .appendingPathComponent(".\(plistURL.lastPathComponent).tmp-\(UUID().uuidString)")
            try payload.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
            try FileManager.default.moveItem(at: temporary, to: plistURL)
        } catch {
            // Login launch is a convenience; the widget should still run if setup fails.
        }
    }

    private static func plistData(appURL: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", appURL.path],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private static func currentAppBundleURL() -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.standardizedFileURL
        }

        var url = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        while url.path != "/" {
            if url.pathExtension == "app" {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
