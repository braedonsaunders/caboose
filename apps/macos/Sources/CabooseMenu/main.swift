import AppKit
import Foundation
import SwiftUI

@MainActor
final class CabooseMenu: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    private var status: NSMenuItem!
    private var timer: Timer?
    private var pairingWindow: NSWindow?
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Caboose", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let resources = Bundle.main.resourceURL
        let bundledVersion = resources.flatMap { try? String(contentsOf: $0.appendingPathComponent("VERSION"), encoding: .utf8) }
        let installedVersion = try? String(contentsOf: directory.appendingPathComponent("current/VERSION"), encoding: .utf8)
        if bundledVersion == nil || bundledVersion == installedVersion {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.caboose.menu")
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.caboose.menu.pair"), object: nil, deliverImmediately: true)
                existing.activate(options: [])
                NSApplication.shared.terminate(nil)
                return
            }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(pairPhone), name: Notification.Name("com.caboose.menu.pair"), object: nil)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "Caboose")
        let menu = NSMenu()
        status = NSMenuItem(title: "Checking Caboose…", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(.separator())
        add("Pair iPhone…", #selector(pairPhone), to: menu)
        add("Open Caboose", #selector(openConsole), to: menu)
        add("Start Host", #selector(startHost), to: menu)
        add("Stop Host", #selector(stopHost), to: menu)
        add("Show Logs", #selector(showLogs), to: menu)
        menu.addItem(.separator())
        add("Quit Menu Bar", #selector(quit), to: menu)
        item.menu = menu
        Task {
            await bootstrap()
            pairPhone()
            refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The outer DMG app embeds the same archive and installer as the CLI release.
    /// Installed login apps omit that payload and simply connect to the current host.
    private func bootstrap() async {
        guard let resources = Bundle.main.resourceURL else { return }
        let archive = resources.appendingPathComponent("runtime.tar.gz")
        let installer = resources.appendingPathComponent("install.sh")
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        let bundled = try? String(contentsOf: resources.appendingPathComponent("VERSION"), encoding: .utf8)
        let installed = try? String(contentsOf: directory.appendingPathComponent("current/VERSION"), encoding: .utf8)
        if bundled != nil && bundled == installed {
            let agent = hostAgent.path
            let domain = "gui/\(getuid())"
            let needsStart = await Task.detached {
                let check = Process()
                check.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                check.arguments = ["print", domain + "/com.caboose.host"]
                check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
                do { try check.run(); check.waitUntilExit(); return check.terminationStatus != 0 }
                catch { return false }
            }.value
            if needsStart { control(["bootstrap", domain, agent]) }
            return
        }
        status.title = "Installing Caboose…"
        let failure = await Task.detached { () -> String? in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [installer.path, "--bundle", archive.path, "--from-app"]
            let output = Pipe()
            task.standardOutput = output; task.standardError = output
            do {
                try task.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                return task.terminationStatus == 0 ? nil : String(data: data, encoding: .utf8) ?? "Installation failed."
            } catch { return error.localizedDescription }
        }.value
        if let failure {
            let alert = NSAlert()
            alert.messageText = "Caboose could not install the host"
            alert.informativeText = failure
            alert.runModal()
        }
    }

    @objc private func pairPhone() {
        if let window = pairingWindow, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let model = PairingModel(directory: directory, port: port)
        let view = PairingView(model: model, openConsole: { [weak self] in self?.openConsole() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Caboose — Pair iPhone"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        pairingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Releasing the hosting view cancels its structured polling task.
        pairingWindow?.contentViewController = nil
        pairingWindow = nil
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
