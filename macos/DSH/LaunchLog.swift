import Foundation

enum LaunchLog {
    static let url: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("DeepSeekHarness.log")
    }()

    private static let lock = NSLock()
    private static var handle: FileHandle?
    private static let maxBytes = 2_000_000

    static func write(_ message: String) {
        appendRaw("\(ISO8601DateFormatter().string(from: Date())) \(message)\n")
    }

    /// Append process stdout/stderr as-is so package `console.log` survives after the overlay hides.
    static func appendOutput(_ chunk: String) {
        appendRaw(chunk)
    }

    private static func appendRaw(_ text: String) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if handle == nil {
            openHandle()
        }
        guard let handle else { return }
        handle.write(data)
        trimIfNeeded(handle)
    }

    private static func openHandle() {
        let path = url.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    private static func trimIfNeeded(_ file: FileHandle) {
        let size = file.offsetInFile
        guard size > maxBytes else { return }
        file.synchronizeFile()
        guard let full = try? Data(contentsOf: url) else { return }
        let keep = full.suffix(maxBytes * 3 / 4)
        try? keep.write(to: url, options: .atomic)
        try? file.close()
        openHandle()
    }
}
