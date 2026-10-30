import CabooseKit
import SwiftUI

/// Over the desktop and app cards while the display is reconnecting: the windows stay, and
/// this says what is happening and that input is not reaching the computer.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if showing {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 12) {
                    if case .waitingForNetwork = model.link.status {
                        Image(systemName: "wifi.slash").foregroundStyle(.orange)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.link.statusLine ?? "Reconnecting")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    ComputerSwitcher {
                        Image(systemName: "desktopcomputer")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityLabel("Switch Computer")
                    if case .reconnecting(_, _, let at?, let reason) = model.link.status, at.timeIntervalSinceNow >= 1 {
                        Button("Try Now") { model.link.retryNow(reason: reason) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .padding(.horizontal, 12)
                .accessibilityElement(children: .combine)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var showing: Bool {
        switch model.link.status {
        case .reconnecting, .waitingForNetwork: true
        case .idle, .live, .lost: false
        }
    }

    private var detail: String {
        let reason = HostMessage.clipped(model.link.reason ?? "", maxLines: 1, maxCharacters: 90)
        let paused = model.session?.windows.isEmpty == false ? "Input is paused. " : ""
        return paused + reason
    }
}

/// What the display connection measured, in Computer settings. Every figure is observed on
/// this phone; a figure with no sample yet shows a dash.
struct ConnectionDiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                linkSection
                measuredSection
                if !model.link.drops.isEmpty { dropsSection }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var health: DisplayLinkHealth { model.session?.health ?? .empty }

    private var linkSection: some View {
        Section {
            LabeledContent("Display", value: displayState)
            if let reason = model.link.reason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            if let host = model.host?.baseURL.host() {
                LabeledContent("Address", value: host + (model.isRemote ? " (remote)" : ""))
            }
            if let path = model.link.path {
                LabeledContent("Network", value: networkDescription(path))
            }
            LabeledContent("Reconnected", value: recoveries)
            if case .lost = model.link.status {
                Button("Try Again") { Task { await model.wake() } }
            }
        } footer: {
            Text("A lost connection is retried up to \(ReconnectPolicy.maxAttempts) times over about a minute, and again whenever the network changes.")
        }
    }

    private var measuredSection: some View {
        Section {
            row("Round trip", samples: health.roundTrip)
            LabeledContent("Last data received", value: health.sinceLastReceive.map { seconds($0) + " ago" } ?? "—")
            LabeledContent("Receiving", value: health.receiveRate.map(bitRate) ?? "—")
            LabeledContent("Pictures", value: health.picturesPerSecond.map { String(format: "%.0f per second", $0) } ?? "—")
            row("Decode", samples: health.decode)
            row("Waiting to decode", samples: health.decodeWait)
            LabeledContent("Failed decodes", value: "\(health.decodeFailures)")
            LabeledContent("Waiting to send", value: backlog)
            LabeledContent("Typing echo", value: health.typingEchoMs.map { "\($0) ms median" } ?? "—")
            if let waiting = health.keyAwaitingPicture, waiting >= 1 {
                LabeledContent("Key without a picture", value: seconds(waiting))
            }
            if let window = model.window(model.presentedWindowID), let session = model.session as? CabooseDisplaySession {
                LabeledContent("This window's last picture", value: session.pictureAge(of: window).map { seconds($0) + " ago" } ?? "—")
            }
        } header: {
            Text("This connection")
        } footer: {
            Text("Round trip is a ping through the host to the computer's display and back. The computer's encode time and the one-way network delay are not measured: the two clocks are not shared.")
        }
    }

    private var dropsSection: some View {
        Section("Recent losses") {
            ForEach(model.link.drops) { drop in
                VStack(alignment: .leading, spacing: 2) {
                    Text(drop.at, style: .relative).font(.subheadline.monospacedDigit()) + Text(" ago").font(.subheadline)
                    Text(drop.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }

    private var displayState: String {
        switch model.link.status {
        case .live: "Connected"
        case .idle: model.session?.state == .ready ? "Connected" : "Not connected"
        case .reconnecting, .waitingForNetwork, .lost: model.link.statusLine ?? "Reconnecting"
        }
    }

    private var recoveries: String {
        switch model.link.recoveries {
        case 0: "Not yet"
        case 1: "Once"
        case let count: "\(count) times"
        }
    }

    private var backlog: String {
        guard let backlog = health.sendBacklog else { return "—" }
        guard backlog.count > 0, let oldest = backlog.oldestMs else { return "Nothing" }
        return "\(backlog.count) · oldest \(Int(oldest.rounded())) ms"
    }

    private func row(_ title: String, samples: DisplayLinkHealth.Samples?) -> some View {
        LabeledContent(title, value: samples.map {
            "\(ms($0.last)) · median \(ms($0.median)) · worst \(ms($0.worst))"
        } ?? "—")
    }

    private func ms(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : "\(Int(value.rounded())) ms"
    }

    private func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f s", value) : "\(Int(value.rounded())) s"
    }

    private func bitRate(_ bits: Double) -> String {
        bits >= 1_000_000 ? String(format: "%.1f Mbit/s", bits / 1_000_000) : String(format: "%.0f kbit/s", bits / 1000)
    }

    private func networkDescription(_ path: NetworkPath) -> String {
        var parts = [path.name]
        if path.expensive { parts.append("metered") }
        if path.constrained { parts.append("Low Data Mode") }
        return parts.joined(separator: ", ")
    }
}
