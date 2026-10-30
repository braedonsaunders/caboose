import AppIntents
import CabooseKit
import Foundation

/// The `/v1/commands` routes (docs/architecture.md, Commands).
extension HostClient {
    /// Starts a command and waits up to `wait` seconds (at most 60) for it to finish. Waking a
    /// parked computer comes first, so the request may take longer than the wait.
    func runCommand(id: String, script: String, stdin: String?, inputs: [String], timeout: Int, wait: Int) async throws -> ComputerCommand {
        let seconds = min(max(wait, 0), 60)
        var body: [String: JSONValue] = [
            "id": .string(id), "script": .string(script), "inputs": .array(inputs.map { .string($0) }),
            "timeout": .int(timeout), "wait": .int(seconds),
        ]
        if let stdin { body["stdin"] = .string(stdin) }
        return try await request("POST", "/v1/commands", body: body, timeout: TimeInterval(seconds) + 300)
    }

    /// The command now, or once it finishes within `wait` seconds (at most 60).
    func command(_ id: String, wait: Int = 0) async throws -> ComputerCommand {
        guard ComputerCommand.isValidID(id) else { throw Failure.server(404, "This command does not exist.") }
        let seconds = min(max(wait, 0), 60)
        return try await request("GET", "/v1/commands/\(id)?wait=\(seconds)", timeout: TimeInterval(seconds) + 30)
    }

    /// Stops a running command; answers once it has ended, or after about ten seconds.
    func cancelCommand(_ id: String) async throws -> ComputerCommand {
        guard ComputerCommand.isValidID(id) else { throw Failure.server(404, "This command does not exist.") }
        return try await request("POST", "/v1/commands/\(id)/cancel", timeout: 120)
    }
}

/// The paired computer's client, for intents and the command view, without the app's connection.
func pairedHostClient() async throws -> HostClient {
    guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
    return HostClient(baseURL: await credentials.reachableURL(), token: credentials.token)
}

/// What Run Command on Computer returns to a shortcut.
struct ComputerCommandResult: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Command Result"
    @Property(title: "Output") var output: String
    @Property(title: "Errors") var errors: String
    @Property(title: "Files") var files: [IntentFile]
    @Property(title: "Status") var status: String
    @Property(title: "Finished") var finished: Bool
    @Property(title: "Exit Code") var exitCode: Int?
    @Property(title: "Link") var link: URL

    init() {}

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(status)", subtitle: "\(String(output.prefix(200)))")
    }
}

struct RunComputerCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Command on Computer"
    static var description = IntentDescription("""
        Runs a Bash script on your computer as you, in a login shell. Input files are in $CABOOSE_IN; \
        files the script saves in $CABOOSE_OUT come back as the result's files. The command keeps \
        running on the computer if the shortcut stops waiting, and Caboose notifies you when it ends.
        """)

    @Parameter(title: "Script", inputOptions: String.IntentInputOptions(multiline: true)) var script: String
    @Parameter(title: "Input Text", description: "Given to the script on standard input.", inputOptions: String.IntentInputOptions(multiline: true)) var input: String?
    @Parameter(title: "Input Files") var files: [IntentFile]?
    @Parameter(title: "Wait for Result", default: true) var waitForResult: Bool
    @Parameter(title: "Wait Up To (Seconds)", default: 25, inclusiveRange: (1, 3600)) var waitSeconds: Int
    @Parameter(title: "Time Limit (Minutes)", default: 60, inclusiveRange: (1, 1440)) var timeLimit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<ComputerCommandResult> & ProvidesDialog {
        guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
        let client = HostClient(baseURL: await credentials.reachableURL(), token: credentials.token)
        let fs = HostShortcutFiles(credentials: credentials)
        let stdin = input.flatMap { $0.isEmpty ? nil : $0 }
        if let stdin, stdin.utf8.count > 1_048_576 {
            throw HostClient.Failure.server(400, "The input text is larger than 1 MiB. Pass it as an input file instead.")
        }
        let id = ComputerCommand.newID()
        let directory = ComputerCommand.directory(for: id)
        let sources = files ?? []
        let names = CommandFileName.assign(sources.map(\.filename))
        if !sources.isEmpty {
            try await fs.mkdir(".caboose-jobs", allowExisting: true)
            try await fs.mkdir(directory)
            try await fs.mkdir(directory + "/in")
            for (file, name) in zip(sources, names) { try await upload(file, to: directory + "/in/" + name, with: fs) }
        }
        let started = Date()
        let budget = waitForResult ? waitSeconds : 0
        var command = try await client.runCommand(id: id, script: script, stdin: stdin, inputs: names, timeout: timeLimit * 60, wait: budget)
        while command.isRunning {
            let remaining = budget - Int(Date().timeIntervalSince(started))
            guard remaining > 0 else { break }
            command = try await client.command(id, wait: remaining)
        }

        var result = ComputerCommandResult()
        result.output = command.stdout
        result.errors = command.stderr
        result.status = command.summary
        result.finished = !command.isRunning
        result.exitCode = command.exitCode
        result.link = command.link
        result.files = []
        if command.isRunning {
            return .result(value: result, dialog: IntentDialog(stringLiteral:
                "Still running on your computer. Caboose notifies you when it ends; open \(command.link.absoluteString) to see it."))
        }
        var outputs: [IntentFile] = []
        for path in command.outputPaths {
            let url = try await fs.download(path)
            var file = IntentFile(fileURL: url, filename: (path as NSString).lastPathComponent)
            file.removedOnCompletion = true
            outputs.append(file)
        }
        result.files = outputs
        // Downloaded results no longer need the job directory; a failed command's stays for inspection.
        if command.status == .succeeded { try? await fs.remove(directory) }
        let detail = command.status == .succeeded
            ? (command.stdout.isEmpty ? "Finished." : String(command.stdout.suffix(1000)))
            : command.summary + (command.stderr.isEmpty ? "" : "\n" + String(command.stderr.suffix(1000)))
        return .result(value: result, dialog: IntentDialog(stringLiteral: detail))
    }

    private func upload(_ file: IntentFile, to path: String, with fs: HostShortcutFiles) async throws {
        let temporary: URL?
        let source: URL
        if let url = file.fileURL { source = url; temporary = nil }
        else {
            source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try file.data.write(to: source, options: .atomic)
            temporary = source
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        try await fs.upload(path, from: source)
    }
}
