import CabooseKit
import SwiftUI

/// The first-computer screen: a host with no computer guides its owner to make one, then
/// follows it while it starts. Shown in place of the tabs while the host has none.
struct FirstComputerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ComputerSwitcher {
                    Label(model.credentials?.hostName ?? "Caboose", systemImage: "server.rack")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            if let creation = model.creation {
                ComputerCreationFlow(creation: creation, first: true)
            } else {
                Spacer()
                ProgressView().tint(.white)
                Spacer()
            }
        }
        .onAppear { model.beginCreatingComputer(presented: false) }
    }
}

/// Making a computer, from choosing its name and size to following it while it starts.
struct ComputerCreationFlow: View {
    let creation: ComputerCreation
    var first = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if creation.stage == .starting {
                SpinningUpView(creation: creation, inSheet: !first)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            } else {
                CreateComputerForm(creation: creation, first: first)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.smooth(duration: 0.45), value: creation.stage == .starting)
    }
}

/// The new computer's name, prefilled, and its size, from those the host can give now.
struct CreateComputerForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Bindable var creation: ComputerCreation
    var first = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    if first {
                        CabooseWordmark(motion: .intro)
                            .frame(height: 52)
                            .foregroundStyle(.white.opacity(0.94))
                            .padding(.bottom, 4)
                    }
                    Text(first ? "Create your first computer" : "Create a computer")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .accessibilityAddTraits(.isHeader)
                    Text(first
                         ? "\(model.credentials?.hostName ?? "This host") has no computer yet. Make one: a real Linux computer that keeps every app where you left it."
                         : "A new computer on \(model.credentials?.hostName ?? "this host"), with its own disk, apps and files.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                if let list = creation.list {
                    if let blocker = list.creationBlocker {
                        blocked(blocker)
                    } else {
                        form(list)
                    }
                } else if let error = creation.formError {
                    unreadable(error)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Reading \(model.credentials?.hostName ?? "the host")…").foregroundStyle(.secondary)
                    }
                    .task { await creation.loadList() }
                }
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private func form(_ list: HostComputerList) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            NativeTextInput("Computer name", text: $creation.name, capitalization: .words, correction: false) {
                if creation.canCreate { Task { await creation.create() } }
            }
            .padding(14)
            .glassEffect(.regular, in: .surface(cornerRadius: 14))
            .disabled(creation.stage != .choosing)
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("Size").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(list.availableSizes) { size in
                SizeOption(size: size, selected: creation.sizeID == size.id) { creation.sizeID = size.id }
                    .disabled(creation.stage != .choosing)
            }
            Text("Memory and processors can be changed later in the computer's settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let error = creation.formError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityLabel("Couldn't create the computer: \(error)")
        }
        Button {
            Task { await creation.create() }
        } label: {
            HStack(spacing: 10) {
                if creation.stage == .creating { ProgressView().tint(.black) }
                Text(creation.stage == .creating ? "Creating…" : "Create Computer")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(Brand.amber)
        .controlSize(.large)
        .disabled(!creation.canCreate)
    }

    private func blocked(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(reason, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let url = model.credentials?.consoleURL {
                    Button("Open Console", systemImage: "arrow.up.right.square") { openURL(url) }
                        .buttonStyle(.glass)
                }
                Button("Check Again", systemImage: "arrow.clockwise") { Task { await creation.loadList() } }
                    .buttonStyle(.glass)
                    .disabled(creation.loadingList)
            }
        }
    }

    private func unreadable(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Couldn't read this host's computers. \(error)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Button("Try Again", systemImage: "arrow.clockwise") { Task { await creation.loadList() } }
                .buttonStyle(.glassProminent)
                .tint(Brand.amber)
                .disabled(creation.loadingList)
        }
    }
}

/// One size a new computer can have, chosen with a tap.
private struct SizeOption: View {
    let size: HostComputerList.Size
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 30)
                    .foregroundStyle(selected ? Brand.amber : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(size.name).font(.body.weight(.semibold))
                    Text(size.summary).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Brand.amber : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .contentShape(Rectangle())
            .glassEffect(.regular, in: .surface(cornerRadius: 16))
            .overlay {
                ConcentricRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? Brand.amber.opacity(0.8) : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var symbol: String {
        switch size.id {
        case "micro": "cpu"
        case "gpu": "cube.transparent"
        default: "desktopcomputer"
        }
    }
}
