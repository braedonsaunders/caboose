import AppKit
import Foundation

@MainActor
final class CabooseMenu: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var status: NSMenuItem!
    private var timer: Timer?
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Caboose", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Caboose")
        let menu = NSMenu()
        status = NSMenuItem(title: "Checking Caboose…", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(.separator())
        add("Open Caboose", #selector(openConsole), to: menu)
        add("Start Host", #selector(startHost), to: menu)
        add("Stop Host", #selector(stopHost), to: menu)
        add("Show Logs", #selector(showLogs), to: menu)
        menu.addItem(.separator())
        add("Quit Menu Bar", #selector(quit), to: menu)
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func add(_ title: String, _ selector: Selector, to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }

    private var port: Int {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("install.json")),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = settings["port"] as? Int, (1...65535).contains(port) else { return 7310 }
        return port
    }

    @objc private func openConsole() {
        var url = URLComponents(string: "http://127.0.0.1:\(port)/")!
        if let code = try? String(contentsOf: directory.appendingPathComponent("disks/setup-code"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            url.path = "/setup"
            url.queryItems = [URLQueryItem(name: "code", value: code)]
        }
        if let target = url.url { NSWorkspace.shared.open(target) }
    }

    private var hostAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.caboose.host.plist")
    }

    private func control(_ arguments: [String]) {
        Task {
            let failure = await Task.detached { () -> String? in
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                task.arguments = arguments
                let errors = Pipe()
                task.standardError = errors
                do {
                    try task.run()
                    // Drain while the process runs, so a full error pipe cannot deadlock it.
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    guard task.terminationStatus != 0 else { return nil }
                    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "launchctl exited with status \(task.terminationStatus)"
                } catch { return error.localizedDescription }
            }.value
            if let failure {
                let alert = NSAlert()
                alert.messageText = "Caboose could not change the host service"
                alert.informativeText = failure
                alert.runModal()
            }
            refresh()
        }
    }

    @objc private func startHost() { control(["bootstrap", "gui/\(getuid())", hostAgent.path]) }
    @objc private func stopHost() { control(["bootout", "gui/\(getuid())/com.caboose.host"]) }
    @objc private func showLogs() { NSWorkspace.shared.open(directory.appendingPathComponent("logs", isDirectory: true)) }
    @objc private func quit() { timer?.invalidate(); NSApplication.shared.terminate(nil) }

    private func refresh() {
        let endpoint = URL(string: "http://127.0.0.1:\(port)/v1/setup")!
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 3
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let claimed = state["claimed"] as? Bool else { throw URLError(.badServerResponse) }
                status.title = claimed ? "Host is running" : "Ready to set up"
            } catch { status.title = "Host is stopped or unreachable" }
        }
    }
}

let app = NSApplication.shared
let delegate = CabooseMenu()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
