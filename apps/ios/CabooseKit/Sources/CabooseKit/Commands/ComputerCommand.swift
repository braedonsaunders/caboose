import Foundation

/// A command run on the computer through `/v1/commands` (docs/architecture.md, Commands):
/// a Bash script run as the owner in `.caboose-jobs/cmd-<id>/`, with its result.
public struct ComputerCommand: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable {
        case running, succeeded, failed, cancelled
        case timedOut = "timed-out"
    }

    public struct Truncation: Decodable, Equatable, Sendable {
        public var stdout: Bool
        public var stderr: Bool
    }

    public var id: String
    public var title: String
    public var script: String
    public var status: Status
    public var exitCode: Int?
    public var signal: String?
    public var error: String?
    public var stdout: String
    public var stderr: String
    public var truncated: Truncation
    /// Names of the files the script left in its out/ directory.
    public var outputs: [String]
    public var createdAt: String
    public var finishedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, script, status, exitCode, signal, error, stdout, stderr, truncated, outputs, createdAt, finishedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        guard Self.isValidID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "A command id is 32 lowercase hex digits.")
        }
        title = try container.decode(String.self, forKey: .title)
        script = try container.decode(String.self, forKey: .script)
        status = try container.decode(Status.self, forKey: .status)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        signal = try container.decodeIfPresent(String.self, forKey: .signal)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        stdout = try container.decode(String.self, forKey: .stdout)
        stderr = try container.decode(String.self, forKey: .stderr)
        truncated = try container.decode(Truncation.self, forKey: .truncated)
        outputs = try container.decode([String].self, forKey: .outputs).filter(CommandFileName.isPlain)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        finishedAt = try container.decodeIfPresent(String.self, forKey: .finishedAt)
    }

    public static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A new id: the phone chooses it so it can stage input files before the command starts.
    public static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The command's job directory, relative to the computer's home.
    public static func directory(for id: String) -> String { ".caboose-jobs/cmd-\(id)" }
    public var directory: String { Self.directory(for: id) }
    /// Home-relative paths of the output files.
    public var outputPaths: [String] { outputs.map { directory + "/out/" + $0 } }
    public var isRunning: Bool { status == .running }
    /// `caboose://command/<id>`: opens this command in the app.
    public var link: URL { URL(string: "caboose://command/\(id)")! }

    /// How the command ended, or that it is still running, in a few words.
    public var summary: String {
        switch status {
        case .running: return "Running"
        case .succeeded: return "Finished"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Stopped at its time limit"
        case .failed:
            if let error { return error }
            if let signal { return "Stopped by \(signal)" }
            return "Exited with code \(exitCode.map(String.init) ?? "unknown")"
        }
    }
}

/// The names of a command's input and output files: one plain component of at most 255 bytes,
/// as the host requires.
public enum CommandFileName {
    public static func isPlain(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && name.utf8.count <= 255
            && !name.hasPrefix(".caboose-upload-")
            && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Plain, distinct names for files sent with a command, keeping each file's own name where
    /// it can: `photo.jpg`, `photo (2).jpg`, …; a name with nothing usable becomes `file`.
    public static func assign(_ filenames: [String]) -> [String] {
        var used = Set<String>()
        return filenames.map { original in
            var scalars = String.UnicodeScalarView()
            for scalar in original.unicodeScalars {
                if scalar.value < 0x20 || scalar.value == 0x7F { scalars.append(" ") }
                else if scalar == "/" { scalars.append("-") }
                else { scalars.append(scalar) }
            }
            var cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
            while cleaned.hasPrefix(".caboose-upload-") { cleaned.removeFirst() }
            if cleaned.isEmpty || cleaned == "." || cleaned == ".." { cleaned = "file" }
            let ext = (cleaned as NSString).pathExtension
            let stem = ext.isEmpty || ext.utf8.count > 32 ? cleaned : (cleaned as NSString).deletingPathExtension
            let suffix = ext.isEmpty || ext.utf8.count > 32 ? "" : "." + ext
            var number = 1
            while true {
                let counter = number == 1 ? "" : " (\(number))"
                let name = fitted(stem, reserving: counter.utf8.count + suffix.utf8.count) + counter + suffix
                if !used.contains(name) {
                    used.insert(name)
                    return name
                }
                number += 1
            }
        }
    }

    /// `stem` cut, by whole characters, so that `reserving` more bytes still fit in 255.
    private static func fitted(_ stem: String, reserving: Int) -> String {
        var result = stem
        while result.utf8.count + reserving > 255, !result.isEmpty { result.removeLast() }
        return result.isEmpty ? "file" : result
    }
}
