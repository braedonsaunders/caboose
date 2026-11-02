import CabooseKit
import SwiftUI

/// A new computer starting, step by step as its host reports it: the system image, its
/// network, its disk, first boot and its display. A bar fills only where the host says how
/// much there is; elsewhere the step under way turns calmly. A step the boot did not need
/// reads as done without work. A failed boot says which step failed and what went wrong,
/// and offers to try again.
struct SpinningUpView: View {
    let creation: ComputerCreation
    /// Shown in the switcher's sheet, which may be closed while the computer goes on starting.
    var inSheet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tracker: BootTracker { creation.tracker }
    private var name: String { creation.created?.name ?? "Your computer" }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                if let boot = tracker.boot {
                    steps(boot)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(tracker.link == .live ? "Waiting for the host to start it…" : "Asking the host how it's going…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 24)
                }
                footer
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: tracker)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: creation.retryError)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                CabooseWheel(motion: tracker.boot?.isFinished == true ? .still : .rolling, lit: !tracker.failed)
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.white.opacity(tracker.failed ? 0.55 : 0.92))
                if tracker.failed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .offset(x: 6, y: 6)
                        .transition(.scale.combined(with: .opacity))
                } else if tracker.succeeded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, Brand.amber)
                        .offset(x: 6, y: 6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.isHeader)
            subtitle
        }
        .padding(.top, 12)
    }

    private var title: String {
        if tracker.succeeded { return "\(name) is ready" }
        if tracker.failed { return "\(name) didn't start" }
        return "Spinning up \(name)"
    }

    @ViewBuilder private var subtitle: some View {
        if let boot = tracker.boot {
            HStack(spacing: 6) {
                if let position = BootStepPresentation.position(in: boot), !boot.isFinished {
                    Text("Step \(position.index) of \(position.count)")
                    Text("·")
                }
                if tracker.succeeded {
                    Text("Opening it now")
                    Text("·")
                }
                Elapsed(boot: boot)
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Steps

    private func steps(_ boot: ComputerBoot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let rows = BootStepPresentation.steps(of: boot)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                BootStepRow(row: row, reduceMotion: reduceMotion)
                if index < rows.count - 1 {
                    Divider().opacity(0.4).padding(.leading, 58)
                }
            }
        }
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .surface(cornerRadius: 22))
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if tracker.failed, let boot = tracker.boot {
            failure(boot)
        } else if case .reconnecting(_, let reason) = tracker.link {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Lost touch with the host. Reconnecting…").font(.footnote.weight(.semibold))
                }
                Text(HostMessage.clipped(reason, maxLines: 2, maxCharacters: 140))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .transition(.opacity)
        } else if inSheet, !tracker.succeeded {
            Text("You can close this. \(name) goes on starting on the host.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func failure(_ boot: ComputerBoot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let step = boot.failedStep {
                Label("Stopped at: \(step.label)", systemImage: "xmark.octagon.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Text(boot.error.flatMap { $0.isEmpty ? nil : $0 } ?? "The host didn't say what went wrong.")
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retryError = creation.retryError {
                Label("Couldn't start it again. \(retryError)", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                Task { await creation.retry() }
            } label: {
                HStack(spacing: 10) {
                    if creation.retrying { ProgressView().tint(.black) } else { Image(systemName: "arrow.clockwise") }
                    Text(creation.retrying ? "Starting Again…" : "Try Again")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.amber)
            .controlSize(.large)
            .disabled(creation.retrying)
        }
        .padding(18)
        .glassEffect(.regular.tint(.red.opacity(0.12)), in: .surface(cornerRadius: 20))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// How long this boot has taken: the host's own start, counted on this phone's clock while it
/// runs, and its finish once it has one.
private struct Elapsed: View {
    let boot: ComputerBoot

    var body: some View {
        if let start = boot.startDate {
            if let finish = boot.finishDate {
                Text(Self.format(finish.timeIntervalSince(start)))
            } else if !boot.isFinished {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.format(context.date.timeIntervalSince(start)))
                }
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// One step: its state, what it is, what it is doing now, and how far it has got when the
/// host knows.
private struct BootStepRow: View {
    let row: BootStepPresentation
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            StepIndicator(indicator: row.indicator, reduceMotion: reduceMotion)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.title)
                    .font(.body.weight(isWorking ? .semibold : .regular))
                    .foregroundStyle(row.indicator == .waiting ? .secondary : .primary)
                if let detail = row.detail {
                    Text(detail)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(row.indicator == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .contentTransition(.numericText())
                }
                if case .working(let fraction?) = row.indicator {
                    ProgressView(value: fraction)
                        .tint(Brand.amber)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(accessibilityState)
    }

    private var isWorking: Bool {
        if case .working = row.indicator { return true }
        return false
    }

    private var accessibilityState: String {
        let detail = row.detail.map { ", \($0)" } ?? ""
        switch row.indicator {
        case .waiting: return "Waiting"
        case .working(let fraction?): return "In progress, \(Int((fraction * 100).rounded())) percent" + detail
        case .working(nil): return "In progress" + detail
        case .done: return "Done" + detail
        case .notNeeded: return "Not needed"
        case .failed: return "Failed" + detail
        }
    }
}

/// The step's state as a ring: empty while waiting, an amber arc turning while under way (or
/// filling, when the host knows how much), amber and checked when done, a quiet check when
/// it was not needed, red when it failed. Under Reduce Motion nothing turns.
private struct StepIndicator: View {
    let indicator: BootStepPresentation.Indicator
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            switch indicator {
            case .waiting:
                Circle().strokeBorder(.white.opacity(0.22), lineWidth: 2)
            case .working(let fraction):
                Circle().strokeBorder(.white.opacity(0.14), lineWidth: 2.5)
                if let fraction {
                    Circle()
                        .inset(by: 1.25)
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(Brand.amber, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth, value: fraction)
                } else {
                    TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
                        let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        Circle()
                            .inset(by: 1.25)
                            .trim(from: 0, to: 0.3)
                            .stroke(Brand.amber, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(turn * 360 - 90))
                    }
                }
                Circle().fill(Brand.amber).frame(width: 7, height: 7)
            case .done:
                Circle().fill(Brand.amber)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
            case .notNeeded:
                Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            case .failed:
                Circle().fill(.red)
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .transition(reduceMotion ? .identity : .scale(scale: 0.6).combined(with: .opacity))
        .id(kind)
    }

    /// Changes of kind (waiting → working → done) cross-fade; progress within a kind animates.
    private var kind: Int {
        switch indicator {
        case .waiting: 0
        case .working(let fraction): fraction == nil ? 1 : 2
        case .done: 3
        case .notNeeded: 4
        case .failed: 5
        }
    }
}
