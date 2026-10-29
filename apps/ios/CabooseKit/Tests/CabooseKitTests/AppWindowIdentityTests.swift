import Testing
@testable import CabooseKit

struct AppWindowIdentityTests {
    @Test func declaredClassCanDifferFromDesktopID() {
        #expect(AppWindowIdentity.matches(desktopID: "vendor-editor.desktop", startupWMClass: "EditorUI", instance: "editor", name: "EditorUI"))
        #expect(!AppWindowIdentity.matches(desktopID: "vendor-editor.desktop", instance: "editor-ui", name: "EditorUI"))
        #expect(!AppWindowIdentity.matches(desktopID: "vendor-editor.desktop", startupWMClass: "EditorUI", instance: "unrelated", name: "Other"))
    }
    @Test func olderHostsAndWaylandIDsStillMatch() {
        #expect(AppWindowIdentity.matches(desktopID: "com.valvesoftware.Steam.desktop", instance: "steam", name: "Steam"))
        #expect(AppWindowIdentity.matches(desktopID: "org.gnome.Evince.desktop", instance: "org.gnome.Evince", name: ""))
        #expect(!AppWindowIdentity.matches(desktopID: ".desktop", instance: "", name: ""))
        #expect(!AppWindowIdentity.matches(desktopID: "example.desktop", startupWMClass: " ", instance: "", name: ""))
    }
}
