#if DEBUG
import Darwin
import Foundation

/// Debug builds keep their standard output and error, which carry the live GPU records
/// (`CABOOSE_GPU_…`), in `Library/Caches/CabooseDiagnostics/console.log` as well as passing
/// them on, so a device's recent history can be read off it without a cable
/// (`xcrun devicectl device copy from --domain-type appDataContainer`). Each launch starts a
/// new file and keeps the previous one as `console.1.log`; a file stops at 16 MiB.
enum ConsoleCapture {
    private static let limit = 16 * 1024 * 1024

    static func start() {
        let directory = URL.cachesDirectory.appending(path: "CabooseDiagnostics", directoryHint: .isDirectory)
        let current = directory.appending(path: "console.log")
        let previous = directory.appending(path: "console.1.log")
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        try? files.removeItem(at: previous)
        try? files.moveItem(at: current, to: previous)
        let file = open(current.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard file >= 0 else { return }
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { close(file); return }
        // Everything still reaches the original output (Xcode, a launch console).
        let originalOut = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        dup2(pipe[1], STDOUT_FILENO); dup2(pipe[1], STDERR_FILENO); close(pipe[1])
        let reader = pipe[0]
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var written = 0
            var lineStart = true
            while true {
                let count = read(reader, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                _ = buffer.withUnsafeBytes { write(originalOut, $0.baseAddress, count) }
                guard written < limit else { continue }
                // Each line starts with the wall-clock time, to line it up with host logs.
                var stamped = Data()
                for byte in buffer.prefix(count) {
                    if lineStart { stamped.append(contentsOf: Array(timestamp().utf8)) }  // UTC
                    stamped.append(byte)
                    lineStart = byte == 0x0a
                }
                _ = stamped.withUnsafeBytes { write(file, $0.baseAddress, stamped.count) }
                written += stamped.count
            }
        }
        thread.name = "caboose.console-capture"
        thread.start()
    }

    private static func timestamp() -> String {
        var now = timeval()
        gettimeofday(&now, nil)
        var parts = tm()
        var seconds = now.tv_sec
        gmtime_r(&seconds, &parts)
        return String(format: "%02d:%02d:%02d.%03d ", parts.tm_hour, parts.tm_min, parts.tm_sec, Int(now.tv_usec) / 1000)
    }
}
#endif
