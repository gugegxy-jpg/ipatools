import Foundation

/// Extension 写、App 读的共享日志（App Group 容器里的一个普通文件）。
/// cb_progress 来自 openconnect 的后台线程，App 侧在主线程读，故加进程内锁。
enum LogStore {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private static var fileURL: URL {
        SharedConfig.containerURL.appendingPathComponent(SharedConfig.logFileName)
    }

    static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let text = "\(formatter.string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let fh = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? fh.close() }
        _ = fh.seekToEndOfFile()
        fh.write(data)
        trimIfNeeded()
    }

    static func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 超过上限就只保留后半段，避免长期挂着把容器写满
    private static func trimIfNeeded() {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attr[.size] as? NSNumber, size.intValue > SharedConfig.maxLogBytes,
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let keep = String(text.suffix(SharedConfig.maxLogBytes / 2))
        try? keep.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
