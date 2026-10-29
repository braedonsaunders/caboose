import SwiftUI

/// Saved pairings only. The phone bearer cannot enumerate the host's computers.
struct ComputerSwitcher<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showingManagement = false
    @ViewBuilder var label: () -> Content

    var body: some View {
        @Bindable var model = model
        Menu {
            Section("Paired Computers") {
                ForEach(model.savedComputers) { computer in
                    Button {
                        model.switchComputer(computer)
                    } label: {
                        Label(computer.displayName, systemImage: computer.id == model.credentials?.id ? "checkmark.circle.fill" : "desktopcomputer")
                        Text(computer.hostURL.host ?? "")
                    }
                    .disabled(model.pairing)
                }
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
        .accessibilityHint("Switch between paired computers or add a computer")
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
