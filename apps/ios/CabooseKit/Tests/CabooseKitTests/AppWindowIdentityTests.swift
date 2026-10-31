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

    @Test func aLaunchedWindowBelongsToItsEntryWhateverItsClass() {
        // A game behind a wrapper script: its SDL window says "vkquake".
        #expect(AppWindowIdentity.matches(desktopID: "com.caboose.QuakeGPUAcceptance.desktop", launchedFrom: "com.caboose.QuakeGPUAcceptance.desktop",
                                          instance: "vkquake", name: "vkquake"))
        // It is not another app whose class it happens to share.
        #expect(!AppWindowIdentity.matches(desktopID: "vkquake.desktop", launchedFrom: "com.caboose.QuakeGPUAcceptance.desktop",
                                           instance: "vkquake", name: "vkquake"))
        // Without a launch, class decides as before.
        #expect(AppWindowIdentity.matches(desktopID: "vkquake.desktop", launchedFrom: nil, instance: "vkquake", name: "vkquake"))
        #expect(!AppWindowIdentity.matches(desktopID: "vkquake.desktop", launchedFrom: nil, instance: nil, name: nil))
    }
}
