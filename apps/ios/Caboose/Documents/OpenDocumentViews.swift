import SwiftUI

struct OpenDocumentPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: OpenDocumentCenter.Pending

    var body: some View {
        let center = model.documents
        let recommended = model.catalog.apps.filter { center.matching($0, pending: item) }
        let other = model.catalog.apps.filter { !center.matching($0, pending: item) && $0.installedVersion != nil }
        NavigationStack {
            List {
                if let error = center.error { Section { Text(error).foregroundStyle(.orange) } }
                if item.copyOnly { Section { Text("The source app sent a copy. Changes on your computer cannot be written back to its original.").foregroundStyle(.orange) } }
                if model.catalog.apps.isEmpty {
                    Section { ProgressView("Loading applications…") }
                } else {
                    if !recommended.isEmpty {
                        Section("Apps for this document") { ForEach(recommended) { row($0) } }
                    } else {
                        Section { Text("No catalog app lists this document type. You can choose another installed app.").foregroundStyle(.secondary) }
                    }
                    if !other.isEmpty { Section("Other installed apps") { ForEach(other) { row($0) } } }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { center.dismiss() }.disabled(center.busy) } }
            .task { await model.catalog.refresh() }
        }
    }

    @ViewBuilder private func row(_ app: CatalogApp) -> some View {
        Button { Task { await model.documents.choose(app, model: model) } } label: {
            HStack {
                if let icon = app.icon { Image(uiImage: icon).resizable().scaledToFit().frame(width: 32, height: 32) }
                else { Image(systemName: "app").frame(width: 32, height: 32) }
                VStack(alignment: .leading) {
                    Text(app.name)
                    if app.installedVersion == nil { Text(app.size.map { "Install · \($0)" } ?? "Install").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if model.documents.installing == app.id {
                    if let value = app.progress?.value { ProgressView(value: value).frame(width: 80) }
                    else { ProgressView() }
                } else { Text(app.installedVersion == nil ? "Get" : "Open").font(.subheadline) }
            }
        }
        .disabled(model.documents.busy)
    }
}
