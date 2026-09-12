import Foundation
import UsageCore


final class ClaudeUsageCollector: @unchecked Sendable {
    private struct FileSignature: Equatable {
        let size: UInt64
        let modifiedAt: Date?
    }

    private let file: URL
    private let queue = DispatchQueue(label: "usage-monitor.claude")
    private let onSnapshot: (UsageSnapshot) -> Void
    private var watcher: FSEventWatcher?
    private var pollTimer: DispatchSourceTimer?
    private var lastSignature: FileSignature?

    init(file: URL, onSnapshot: @escaping (UsageSnapshot) -> Void) {
        self.file = file
        self.onSnapshot = onSnapshot
    }

    deinit {
        pollTimer?.cancel()
    }

    func start() {
        queue.async {
            self.readIfChanged(force: true)
            let directory = self.file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.watcher = FSEventWatcher(paths: [directory.path]) { [weak self] in
                guard let collector = self else {
                    return
                }
                collector.queue.async {
                    collector.readIfChanged(force: true)
                }
            }
            self.watcher?.start()
            self.startPollTimer()
        }
    }

    private func startPollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            self?.readIfChanged(force: false)
        }
        pollTimer = timer
        timer.resume()
    }

    private func readIfChanged(force: Bool) {
        guard let signature = fileSignature() else {
            return
        }
        guard force || signature != lastSignature else {
            return
        }
        guard
            let data = try? Data(contentsOf: file),
            let snapshot = ClaudeStatusLineParser.parseData(data)
        else {
            return
        }
        lastSignature = signature
        DispatchQueue.main.async {
            self.onSnapshot(snapshot)
        }
    }

    private func fileSignature() -> FileSignature? {
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        guard values.fileSize != nil || values.contentModificationDate != nil else {
            return nil
        }
        return FileSignature(
            size: UInt64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate
        )
    }
}
