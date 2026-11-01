import Testing
@testable import CabooseKit

struct TaskbarTests {
    typealias W = Taskbar.Window
    typealias E = Taskbar.Entry

    let entries = [
        E(id: "com.valvesoftware.Steam.desktop", name: "Steam", exec: "/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=/app/bin/steam-wrapper com.valvesoftware.Steam %U"),
        E(id: "org.gnome.TextEditor.desktop", name: "Text Editor", exec: "gnome-text-editor %U"),
        E(id: "thunar.desktop", name: "Thunar", startupWMClass: "Thunar", exec: "thunar %F"),
        E(id: "thunar-bulk-rename.desktop", name: "Bulk Rename", exec: "thunar --bulk-rename %F"),
        E(id: "google-chrome.desktop", name: "Google Chrome", exec: "/usr/bin/google-chrome-stable %U"),
        E(id: "debian-uxterm.desktop", name: "UXTerm", exec: "uxterm"),
    ]

    @Test func aWindowNoEntryClaimsIsStillRunning() {
        // Halo, which Steam started: its Proton window's class names no entry.
        let bar = Taskbar(windows: [W(id: 25, title: "Steam", instance: "steam", name: "steam", pid: 280),
                                    W(id: 36, title: "Halo: The Master Chief Collection  ", instance: "steam_app_976730", name: "steam_app_976730", pid: 2113)],
                          entries: entries)
        #expect(bar.groups.map(\.id) == ["com.valvesoftware.Steam.desktop", "window:class:steam_app_976730"])
        let halo = bar.group(of: 36)
        #expect(halo?.entryID == nil && halo?.name == "Halo: The Master Chief Collection" && halo?.windows == [36])
        #expect(bar.group(of: 25)?.name == "Steam")
    }

    @Test func aSteamGameMatchesTheEntrySteamWrote() {
        let game = E(id: "Halo The Master Chief Collection.desktop", name: "Halo: The Master Chief Collection",
                     exec: "flatpak run com.valvesoftware.Steam steam://rungameid/976730")
        let other = E(id: "Other.desktop", name: "Other", exec: "steam steam://rungameid/9767301")
        let bar = Taskbar(windows: [W(id: 1, instance: "steam_app_976730", name: "steam_app_976730")], entries: [other, game])
        #expect(bar.group(of: 1)?.entryID == "Halo The Master Chief Collection.desktop")
    }

    @Test func everyWindowBelongsToOneGroupAndTheBestEntry() {
        let bar = Taskbar(windows: [W(id: 1, instance: "Thunar", name: "Thunar"), W(id: 2, instance: "Thunar", name: "Thunar"),
                                    W(id: 3, instance: "org.gnome.TextEditor", name: "org.gnome.TextEditor"),
                                    W(id: 4, instance: "google-chrome-stable", name: "Google-chrome-stable")],
                          entries: entries)
        // Thunar, not Bulk Rename, whose id merely ends differently.
        #expect(bar.groups.map(\.id) == ["thunar.desktop", "org.gnome.TextEditor.desktop", "google-chrome.desktop"])
        #expect(bar.group(of: 2)?.windows == [1, 2])
    }

    @Test func aLaunchNamesTheEntryWhateverTheClass() {
        let bar = Taskbar(windows: [W(id: 1, instance: "vkquake", name: "vkquake", desktopID: "thunar-bulk-rename.desktop")], entries: entries)
        #expect(bar.group(of: 1)?.entryID == "thunar-bulk-rename.desktop")
        // A launch from an entry the computer does not list leaves the class to decide.
        let unlisted = Taskbar(windows: [W(id: 1, instance: "Thunar", name: "Thunar", desktopID: "gone.desktop")], entries: entries)
        #expect(unlisted.group(of: 1)?.entryID == "thunar.desktop")
    }

    @Test func aProcessKeepsItsWindowsTogether() {
        // A splash window with a class of its own, and a classless window, of a matched process.
        let bar = Taskbar(windows: [W(id: 5, instance: "splash", name: "Splash", pid: 70), W(id: 6, instance: "Thunar", name: "Thunar", pid: 70),
                                    W(id: 7, pid: 70)], entries: entries)
        #expect(bar.groups.map(\.id) == ["thunar.desktop"])
        #expect(bar.group(of: 5)?.windows == [5, 6, 7])
    }

    @Test func unclaimedWindowsGroupByClassThenProcess() {
        let bar = Taskbar(windows: [W(id: 1, title: "~", instance: "xterm", name: "XTerm", pid: 10), W(id: 2, title: "logs", instance: "xterm", name: "XTerm", pid: 11),
                                    W(id: 3, title: "Untitled", pid: 12), W(id: 4, title: "Other", pid: 12), W(id: 5)], entries: [])
        #expect(bar.groups.map(\.id) == ["window:class:xterm", "window:pid:12", "window:id:5"])
        #expect(bar.groups.map(\.name) == ["XTerm", "Untitled", "Window"])
        #expect(bar.group(of: 2)?.windows == [1, 2])
    }

    @Test func closingTheLastWindowEndsTheGroup() {
        let open = Taskbar(windows: [W(id: 1, instance: "xterm", name: "XTerm"), W(id: 2, instance: "xterm", name: "XTerm")], entries: [])
        #expect(open.groups.count == 1)
        let one = Taskbar(windows: [W(id: 2, instance: "xterm", name: "XTerm")], entries: [])
        #expect(one.groups.first?.windows == [2])
        #expect(Taskbar(windows: [], entries: entries).groups.isEmpty)
        #expect(one.group(of: 1) == nil)
    }

    @Test func groupsKeepTheOrderTheyOpenedIn() {
        let bar = Taskbar(windows: [W(id: 9, instance: "Thunar", name: "Thunar"), W(id: 3, instance: "b", name: "b"), W(id: 4, instance: "Thunar", name: "Thunar")],
                          entries: entries)
        #expect(bar.groups.map(\.id) == ["window:class:b", "thunar.desktop"])
    }

    @Test func execNamesItsProgram() {
        #expect(Taskbar.program("/usr/bin/google-chrome-stable %U") == "google-chrome-stable")
        #expect(Taskbar.program("env GDK_BACKEND=x11 -u FOO /opt/app/App --flag") == "app")
        #expect(Taskbar.program("flatpak run --branch=stable org.gimp.GIMP %U") == "org.gimp.gimp")
        #expect(Taskbar.program("") == nil)
        #expect(Taskbar.steamGame("steam_app_976730") == "976730")
        #expect(Taskbar.steamGame("steam_app_") == nil && Taskbar.steamGame("steam") == nil)
    }

    @Test func dockFitNeverDropsARunningApp() {
        let items = Array(1...6)
        #expect(DockFit.visible(items, fit: 10) { _ in false } == items)
        #expect(DockFit.visible(items, fit: 3) { $0 == 6 } == [1, 2, 6])
        #expect(DockFit.visible(items, fit: 3) { $0 >= 4 } == [4, 5, 6])
        #expect(DockFit.visible(items, fit: 2) { $0 >= 4 } == [4, 5])
    }
}
