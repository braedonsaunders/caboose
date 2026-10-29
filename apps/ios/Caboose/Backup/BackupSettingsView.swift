import CabooseKit
import SwiftUI

/// Backups of this computer's disk kept on this phone or in iCloud Drive, and restores from them.
struct BackupSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: HostClient.BackupStatus?
    @State private var loadError: String?
    @State private var enabled = false
    @State private var location = BackupStore.location
    @State private var iCloudAvailable = false
    @State private var snapshots: [ChunkVault.Snapshot] = []
    @State private var storedBytes: Int64 = 0
    @State private var others: [BackupStore.StoredVault] = []
    @State private var progress: BackupEngine.Progress?
    @State private var working = false
    @State private var actionError: String?
    @State private var restoreCandidate: (snapshot: ChunkVault.Snapshot, directory: URL, from: String)?
    @State private var restored = false

    private var credentials: Credentials? { model.credentials }

    var body: some View {
        Form {
            if let loadError {
                Section { StatusRow(title: "Backups unavailable", systemImage: "exclamationmark.triangle", tint: .orange, message: loadError) }
            }
            if let status, !status.available {
                Section { StatusRow(title: "This host cannot make backups", systemImage: "externaldrive.badge.xmark", tint: .secondary, message: status.reason) }
            }
            Section {
                Toggle("Back Up to This Phone", isOn: Binding(get: { enabled }, set: { value in Task { await setEnabled(value) } }))
                    .disabled(status?.available != true || working)
                Picker("Keep Backups", selection: Binding(get: { location }, set: { value in
                    location = value
                    BackupStore.location = value
                    Task { await load() }
                })) {
                    ForEach(BackupStore.Location.allCases) { place in
                        Text(place.title).tag(place).disabled(place == .iCloud && !iCloudAvailable)
                    }
                }
                .disabled(working)
            } footer: {
                Text("Your phone keeps a copy of the computer's disk: everything you installed and saved. Only what differs from the computer's original image is stored, encrypted with a key in your iCloud Keychain. New backups happen overnight while your phone charges.\(iCloudAvailable ? "" : " To use iCloud Drive, sign in to iCloud and turn on iCloud Drive.")")
            }
            if enabled {
                Section {
                    LabeledContent("Last backup", value: snapshots.last?.info.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "None yet")
                    LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file))
                    if let capture = status?.capture {
                        LabeledContent("Newest on the computer", value: capture.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? capture.createdAt)
                    }
                    if status?.pending == true || status?.capturing == true {
                        Label("A new backup is taken the next time the computer sleeps", systemImage: "moon.zzz").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let progress {
                        VStack(alignment: .leading) {
                            Text(progress.message).font(.footnote)
                            if let fraction = progress.fraction { ProgressView(value: fraction) } else { ProgressView() }
                            if progress.total > 0 {
                                Text("\(ByteCountFormatter.string(fromByteCount: progress.done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Back Up Now") { Task { await backUp() } }.disabled(working)
                    if let actionError { Text(actionError).font(.footnote).foregroundStyle(.orange) }
                }
            }
            if !snapshots.isEmpty {
                Section {
                    ForEach(snapshots.reversed()) { snapshot in
                        restoreRow(snapshot, directory: vaultDirectory, from: credentials?.displayName ?? "this computer")
                    }
                } header: {
                    Text("Restore")
                } footer: {
                    Text("Restoring replaces the computer's disk with the backup and restarts it. Anything newer than the backup is lost.")
                }
            }
            ForEach(others) { vault in
                Section(vault.label?.computerName ?? "Another computer") {
                    OtherVaultRows(vault: vault) { snapshot in
                        restoreCandidate = (snapshot, vault.directory, vault.label?.computerName ?? "another computer")
                    }
                    .disabled(working || status?.available != true)
                }
            }
            if restored {
                Section { Label("Restored. The computer is starting from the backup.", systemImage: "checkmark.circle").foregroundStyle(.green) }
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }), titleVisibility: .visible) {
            Button("Replace Disk and Restart", role: .destructive) {
                if let candidate = restoreCandidate { Task { await restore(candidate.snapshot, from: candidate.directory) } }
            }
        } message: {
            if let candidate = restoreCandidate {
                Text("\(credentials?.displayName ?? "This computer") restarts from \(candidate.from)'s backup of \(candidate.snapshot.info.date?.formatted(date: .abbreviated, time: .shortened) ?? candidate.snapshot.info.createdAt). Open apps close, and everything newer than the backup is lost.")
            }
        }
    }

    private var vaultDirectory: URL? { credentials.flatMap { BackupStore.vaultDirectory(for: $0.id, in: location) } }

    private func restoreRow(_ snapshot: ChunkVault.Snapshot, directory: URL?, from: String) -> some View {
        Button {
            if let directory { restoreCandidate = (snapshot, directory, from) }
        } label: {
            LabeledContent(snapshot.info.date?.formatted(date: .abbreviated, time: .shortened) ?? snapshot.info.createdAt,
                           value: ByteCountFormatter.string(fromByteCount: snapshot.info.dataBytes, countStyle: .file))
        }
        .disabled(working || status?.available != true)
    }

    private func load() async {
        guard let credentials, let host = model.host else { return }
        enabled = BackupStore.enabled.contains(credentials.id)
        do {
            status = try await host.backupStatus()
            loadError = nil
            if let status { enabled = enabled && status.enabled }
        } catch { loadError = error.localizedDescription }
        let id = credentials.id, place = location
        let local = await Task.detached { () -> (Bool, [ChunkVault.Snapshot], Int64, [BackupStore.StoredVault]) in
            let iCloud = BackupStore.root(.iCloud) != nil
            var snapshots: [ChunkVault.Snapshot] = [], bytes: Int64 = 0
            if let directory = BackupStore.vaultDirectory(for: id, in: place), FileManager.default.fileExists(atPath: directory.appendingPathComponent("vault.json").path),
               let key = try? BackupKey.load(), let vault = try? ChunkVault.open(directory: directory, key: key) {
                snapshots = (try? vault.snapshots()) ?? []
                bytes = vault.storedBytes
            }
            let others = ((try? BackupStore.vaults()) ?? []).filter { $0.directory.lastPathComponent != id }
            return (iCloud, snapshots, bytes, others)
        }.value
        (iCloudAvailable, snapshots, storedBytes, others) = local
    }

    private func setEnabled(_ value: Bool) async {
        guard let credentials, let host = model.host else { return }
        working = true
        defer { working = false }
        do {
            status = try await host.setBackups(enabled: value)
            if value { BackupStore.enabled.insert(credentials.id) } else { BackupStore.enabled.remove(credentials.id) }
            enabled = value
            BackupScheduler.schedule()
            actionError = nil
        } catch { actionError = error.localizedDescription }
        await load()
    }

    private func backUp() async {
        guard let credentials else { return }
        working = true
        defer { working = false; progress = nil }
        do {
            switch try await BackupEngine.shared.backUp(credentials, progress: { value in Task { @MainActor in progress = value } }) {
            case .stored: actionError = nil
            case .waiting: actionError = "The computer has no backup yet. One is taken the next time it sleeps."
            case .unavailable(let reason): actionError = reason
            }
        } catch { actionError = error.localizedDescription }
        await load()
    }

    private func restore(_ snapshot: ChunkVault.Snapshot, from directory: URL) async {
        guard let credentials else { return }
        working = true
        restored = false
        defer { working = false; progress = nil }
        do {
            try await BackupEngine.shared.restore(snapshot, from: directory, onto: credentials, progress: { value in Task { @MainActor in progress = value } })
            restored = true
            actionError = nil
        } catch { actionError = error.localizedDescription }
        await load()
    }
}

/// The captures in a vault of another computer, any of which can be restored onto this one.
private struct OtherVaultRows: View {
    let vault: BackupStore.StoredVault
    let choose: (ChunkVault.Snapshot) -> Void
    @State private var snapshots: [ChunkVault.Snapshot] = []

    var body: some View {
        Group {
            if snapshots.isEmpty {
                Text("No complete backups").foregroundStyle(.secondary)
            }
            ForEach(snapshots.reversed()) { snapshot in
                Button { choose(snapshot) } label: {
                    LabeledContent(snapshot.info.date?.formatted(date: .abbreviated, time: .shortened) ?? snapshot.info.createdAt,
                                   value: ByteCountFormatter.string(fromByteCount: snapshot.info.dataBytes, countStyle: .file))
                }
            }
        }
        .task {
            let directory = vault.directory
            snapshots = await Task.detached {
                guard let key = try? BackupKey.load(), let opened = try? ChunkVault.open(directory: directory, key: key) else { return [] }
                return (try? opened.snapshots()) ?? []
            }.value
        }
    }
}
