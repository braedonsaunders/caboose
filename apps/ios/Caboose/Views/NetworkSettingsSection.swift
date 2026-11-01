import CabooseKit
import SwiftUI

/// The computer as a machine on your network (docs/network.md): its own tailnet name and
/// address, the servers running on it, and how to reach them from any app on any of your
/// devices with Tailscale. Nothing here goes through Caboose; apps connect directly.
struct NetworkSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let network: ComputerNetwork
    let forwardLoopback: Bool
    @State private var saveError: String?

    var body: some View {
        Section {
            if let tailnet = network.tailnet {
                switch tailnet.state {
                case "running":
                    if let name = tailnet.name {
                        LabeledContent("Name") { Text(name).textSelection(.enabled) }
                    }
                    if let ipv4 = tailnet.ipv4 {
                        LabeledContent("Address") { Text(ipv4).textSelection(.enabled) }
                    }
                    if let host = network.host {
                        ForEach(network.servers ?? []) { server in serverRow(server, host: host) }
                    }
                    Toggle("Share Localhost Servers", isOn: Binding(get: { forwardLoopback }, set: { value in
                        Task {
                            do { try await model.saveSettings(["forwardLoopback": .bool(value)]); saveError = nil }
                            catch { saveError = error.localizedDescription }
                        }
                    }))
                case "needs-login":
                    if let url = tailnet.loginUrl {
                        Button("Add to Tailscale") { openURL(url) }
                    }
                    Text("Sign in once to give this computer its own name on your tailnet.")
                        .font(.footnote).foregroundStyle(.secondary)
                case "needs-approval":
                    StatusRow(title: "Waiting for Approval", systemImage: "hourglass", tint: .secondary,
                              message: "Approve this computer in the Tailscale admin console.")
                case "error":
                    StatusRow(title: "Not on Your Tailnet", systemImage: "exclamationmark.triangle", tint: .orange, message: tailnet.error)
                default:
                    Label { Text("Joining your tailnet…") } icon: { ProgressView() }
                }
            }
            if let saveError { Text(saveError).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Network")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        guard let host = network.host else {
            return "Your computer becomes a device on your Tailscale network, like a server on your desk."
        }
        let sharing = forwardLoopback
            ? " Servers that listen only on localhost, such as Vite or Django, are shared too."
            : " Servers that listen only on localhost stay private."
        return "Any server you start is reachable at \(host) from your devices with Tailscale, such as http://\(host):8000 in Safari or \(host):5432 in a database app.\(sharing) A running server keeps the computer awake."
    }

    @ViewBuilder
    private func serverRow(_ server: ComputerNetwork.Server, host: String) -> some View {
        if let url = server.url(host: host) {
            Button { openURL(url) } label: {
                LabeledContent(server.label, value: "\(server.port)")
            }
            .contextMenu { Button("Copy Address") { UIPasteboard.general.string = url.absoluteString } }
        } else {
            LabeledContent(server.label) {
                Text(server.protocol == "udp" ? "\(server.port) UDP" : server.address(host: host)).textSelection(.enabled)
            }
        }
    }
}
