import SwiftUI

/// The saved sign-ins, and for a host sign-in the host's own computers: switch between
/// them, make another, or sign in to more. A sign-in paired to one computer cannot list the
/// host's others.
struct ComputerSwitcher<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showingManagement = false
    @ViewBuilder var label: () -> Content

    var body: some View {
        @Bindable var model = model
        Menu {
            if let credentials = model.credentials, credentials.isHostSignIn, let list = model.hostComputers, !list.computers.isEmpty {
                Section("On \(credentials.hostName)") {
                    ForEach(list.computers) { computer in
                        Button {
                            model.openHostComputer(id: computer.id, name: computer.name)
                        } label: {
                            Label(computer.name, systemImage: computer.id == credentials.computerID ? "checkmark.circle.fill" : "desktopcomputer")
                            Text(computer.stateTitle)
                        }
                        .disabled(model.pairing)
                    }
                }
            }
            Section("Paired Computers") {
                ForEach(model.savedComputers) { computer in
                    Button {
                        model.switchComputer(computer)
                    } label: {
                        if computer.isHostSignIn {
                            Label(computer.hostName, systemImage: computer.id == model.credentials?.id ? "checkmark.circle.fill" : "server.rack")
                            Text(computer.computerName.map { "Host · \($0)" } ?? "Host · every computer")
                        } else {
                            Label(computer.displayName, systemImage: computer.id == model.credentials?.id ? "checkmark.circle.fill" : "desktopcomputer")
                            Text(computer.hostName)
                        }
                    }
                    .disabled(model.pairing)
                }
            }
            if model.credentials?.isHostSignIn == true, model.phase != .noComputer, model.hostComputers?.allowsCreating == true {
                Button("Create a Computer", systemImage: "plus.rectangle.on.rectangle") { model.beginCreatingComputer(presented: true) }
                    .disabled(model.pairing)
            }
            Button("Add Computer", systemImage: "plus") { model.addingComputer = true }
            if model.credentials?.consoleURL != nil {
                Button("Manage Computers", systemImage: "arrow.up.right.square") { showingManagement = true }
            }
        } label: {
            HStack(spacing: 10) {
                label()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Computer: \(model.credentials?.displayName ?? "Caboose")")
        .accessibilityHint("Switch between computers, create one or add one")
        .task(id: model.credentials?.id) { await model.refreshHostComputers() }
        .sheet(isPresented: Binding(get: { model.creatingComputer }, set: { if !$0 { model.endCreatingComputer() } })) {
            NavigationStack {
                ZStack {
                    Backdrop()
                    if let creation = model.creation {
                        ComputerCreationFlow(creation: creation)
                    }
                }
                .navigationTitle("New Computer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.creation?.stage == .starting ? "Close" : "Cancel") { model.endCreatingComputer() }
                            .disabled(model.creation?.stage == .creating)
                    }
                }
            }
            .environment(model)
            .preferredColorScheme(.dark)
            .interactiveDismissDisabled(model.creation?.stage == .creating)
        }
        .sheet(isPresented: $model.addingComputer) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 0) {
                        if let failure = model.pairingFailure {
                            Text(failure)
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 28)
                                .accessibilityLabel("Pairing failed: \(failure)")
                        }
                        SetupView()
                    }
                }
                    .navigationTitle("Add Computer")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { model.addingComputer = false }
                                .disabled(model.pairing)
                        }
                    }
            }
            .interactiveDismissDisabled(model.pairing)
        }
        .alert("Manage Computers", isPresented: $showingManagement) {
            Button("Open Console") {
                if let url = model.credentials?.consoleURL { openURL(url) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Sign in to the console with an authorized administrator account to provision computers and create pairing codes. Pair each computer here to add it to this menu.")
        }
    }
}
