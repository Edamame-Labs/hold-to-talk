import Foundation

// MARK: - Shared debug file logger

let debugLogPath: String = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = appSupport.appendingPathComponent("HoldToTalk")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("debug.log").path
}()

/// Owns all mutable logger state. The unchecked conformance is safe because the
/// formatter and file handle are accessed only on `queue`.
private final class DebugLogWriter: @unchecked Sendable {
    private let maxLogSize: UInt64 = 1_048_576
    private let queue = DispatchQueue(label: "com.holdtotalk.debuglog", qos: .utility)
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?

    func write(_ message: String) {
        queue.async { [self] in
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8),
                  let handle = ensureHandle() else { return }
            handle.write(data)
        }
    }

    func truncateIfNeeded() {
        queue.sync {
            closeHandle()

            guard FileManager.default.fileExists(atPath: debugLogPath),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: debugLogPath),
                  let size = attrs[.size] as? UInt64,
                  size > maxLogSize,
                  let data = FileManager.default.contents(atPath: debugLogPath) else { return }

            let keepFrom = data.count / 2
            let trimmed = data.subdata(in: keepFrom..<data.count)
            if let newlineIndex = trimmed.firstIndex(of: UInt8(ascii: "\n")) {
                let clean = trimmed.subdata(in: trimmed.index(after: newlineIndex)..<trimmed.endIndex)
                try? clean.write(to: URL(fileURLWithPath: debugLogPath))
            } else {
                try? trimmed.write(to: URL(fileURLWithPath: debugLogPath))
            }
        }
    }

    func clear(fileManager: FileManager) {
        queue.sync {
            closeHandle()
            guard fileManager.fileExists(atPath: debugLogPath) else { return }
            try? fileManager.removeItem(atPath: debugLogPath)
        }
    }

    private func ensureHandle() -> FileHandle? {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: debugLogPath) {
            FileManager.default.createFile(atPath: debugLogPath, contents: nil)
        }
        let newHandle = FileHandle(forWritingAtPath: debugLogPath)
        newHandle?.seekToEndOfFile()
        handle = newHandle
        return newHandle
    }

    private func closeHandle() {
        handle?.closeFile()
        handle = nil
    }
}

private let debugLogWriter = DebugLogWriter()

func isDiagnosticLoggingEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: diagnosticLoggingEnabledDefaultsKey)
}

func diagnosticLogRedactionSummary(for text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "<redacted empty>" }
    let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
    return "<redacted \(trimmed.count) chars, \(wordCount) words>"
}

/// Truncates the debug log file if it exceeds `maxLogSize`.
/// Call once at app startup. Runs synchronously on the writer queue so it completes
/// before the first `debugLog()` call and opens the persistent handle on a clean file.
func truncateDebugLogIfNeeded() {
    debugLogWriter.truncateIfNeeded()
}

func clearDebugLog(fileManager: FileManager = .default) {
    debugLogWriter.clear(fileManager: fileManager)
}

func debugLogSensitive(_ label: String, text: String) {
    debugLog("\(label): \(diagnosticLogRedactionSummary(for: text))")
}

func debugLog(_ message: String) {
    #if DEBUG
    print(message)
    #endif
    guard isDiagnosticLoggingEnabled() else { return }
    debugLogWriter.write(message)
}
