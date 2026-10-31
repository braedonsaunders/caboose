import AppIntents
import SwiftUI

struct ShortcutsSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                ShortcutsSettingsView()
            } label: {
                Label("Shortcuts", systemImage: "square.stack.3d.up")
            }
        }
    }
}

private struct ShortcutsSettingsView: View {
    var body: some View {
        List {
            Section {
                ShortcutsLink()
                Link(destination: URL(string: "shortcuts://create-shortcut")!) {
                    Label("Create a Shortcut", systemImage: "plus")
                }
            } footer: {
                Text("Choose Caboose actions in the Shortcuts app, set their options, and save your own shortcuts. You can add them to your Home Screen, use them with Siri, or include them in automations.")
            }
            Section("Export Files") {
                Text("Add Export Files, then choose an app, input files and output format. Use files from an earlier action or Ask Each Time. Send the exported files to Save File, Share, or another action.")
                LabeledContent("PhotoCraft", value: "Convert 1–20 images")
                LabeledContent("LightCraft", value: "Develop one photo")
                LabeledContent("FilmCraft", value: "Export one project")
                Text("Install the selected app from Library on your computer before running an export. FilmCraft projects need their media at its original paths on the computer.")
                    .foregroundStyle(.secondary)
            }
            Section("Apps and Files") {
                Text("Use Open Linux App to choose an installed app, or Run Linux App Action to choose an action such as New Window. Get and Save Computer File connect your computer’s files to other shortcut actions. Combine PDFs joins documents into one file.")
            }
        }
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
