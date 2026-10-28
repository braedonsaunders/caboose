import Foundation
import FoundationModels

/// What the iPhone's on-device agent can do to the computer. The app carries these out
/// through the host; `OnDeviceEval` records them to measure the model. Each returns a short
/// sentence the model reads back.
protocol ComputerActions: Sendable {
    func launch(app: String) async throws -> String
    func open(url: String) async throws -> String
    func type(text: String, pressReturn: Bool) async throws -> String
    func press(keys: String) async throws -> String
    func park() async throws -> String
    func delegate(task: String, agent: String?) async throws -> String
    /// The focused window's controls, numbered.
    func look() async throws -> String
    func click(element number: Int) async throws -> String
}

/// The on-device agent's tools and instructions, shared by the app and its evaluation so the
/// measurement is of exactly what ships.
enum OnDeviceTools {
    static func all(_ actions: any ComputerActions) -> [any Tool] {
        [LaunchApp(actions: actions), OpenURL(actions: actions), TypeText(actions: actions), PressKeys(actions: actions),
         LookAtScreen(actions: actions), ClickElement(actions: actions), ParkComputer(actions: actions), Delegate(actions: actions)]
    }

    /// Apps as the model should see them: the name, and what it is for when the desktop entry says.
    static func describe(app name: String, categories: [String]) -> String {
        let kinds: [(String, String)] = [
            ("Spreadsheet", "spreadsheets"), ("Presentation", "slides"), ("WordProcessor", "documents"),
            ("WebBrowser", "web browser"), ("TextEditor", "text editor"), ("TerminalEmulator", "terminal"),
            ("FileManager", "files"), ("IDE", "code editor"), ("Viewer", "viewer"), ("Settings", "settings"),
        ]
        let kind = kinds.first { categories.contains($0.0) }?.1
        return kind.map { "\(name) (\($0))" } ?? name
    }

    static func instructions(apps: [String], agents: [String]) -> String {
        """
        You are the Ask bar in Caboose, an iPhone app for the user's own Linux computer. You act by calling tools.
        Do quick things yourself:
        - open an app: launch_app
        - open a web page or a web search: open_url
        - type text into the window that already has focus: type_text, with the user's exact words. Do not open an app first unless asked.
        - press a shortcut in the focused window: press_keys. ctrl+s save, ctrl+z undo, ctrl+shift+z redo, ctrl+t new tab, \
        ctrl+w close tab, alt+f4 close window, ctrl+f find, ctrl+c copy, ctrl+v paste.
        - press a button, link, tab or option the user names: look_at_screen, then click_element with its number.
        - put the computer to sleep: park_computer
        Hand anything that needs several steps, code, files, research or judgement to an agent with delegate, \
        writing a complete task description. Composing something new — a message, a poem, a document — is work for an agent; \
        type_text only types words the user gave you.
        If the user is only chatting, reply in one short sentence and call no tool.
        Never type shell commands that delete or overwrite files.
        Apps: \(apps.joined(separator: ", ")).
        Agents for delegate: \(agents.joined(separator: ", ")).
        """
    }
}

struct LaunchApp: Tool {
    let actions: any ComputerActions
    let name = "launch_app"
    let description = "Open an application on the computer."
    @Generable struct Arguments {
        @Guide(description: "The application's name, exactly as it appears in the apps list")
        var app: String
    }
    func call(arguments: Arguments) async throws -> String { try await actions.launch(app: arguments.app) }
}

struct OpenURL: Tool {
    let actions: any ComputerActions
    let name = "open_url"
    let description = "Open a web address in the computer's browser. For a web search, open a search URL."
    @Generable struct Arguments {
        @Guide(description: "A full http or https URL")
        var url: String
    }
    func call(arguments: Arguments) async throws -> String { try await actions.open(url: arguments.url) }
}

struct TypeText: Tool {
    let actions: any ComputerActions
    let name = "type_text"
    let description = "Type text into the window that has focus on the computer."
    @Generable struct Arguments {
        @Guide(description: "The exact text to type")
        var text: String
        @Guide(description: "Press Return after typing")
        var pressReturn: Bool
    }
    func call(arguments: Arguments) async throws -> String { try await actions.type(text: arguments.text, pressReturn: arguments.pressReturn) }
}

struct PressKeys: Tool {
    let actions: any ComputerActions
    let name = "press_keys"
    let description = "Press a keyboard shortcut in the focused window, such as ctrl+s or alt+tab."
    @Generable struct Arguments {
        @Guide(description: "Keys joined with +, lowercase, e.g. ctrl+s, ctrl+shift+t, escape")
        var keys: String
    }
    func call(arguments: Arguments) async throws -> String { try await actions.press(keys: arguments.keys) }
}

struct LookAtScreen: Tool {
    let actions: any ComputerActions
    let name = "look_at_screen"
    let description = "List the numbered buttons, links, fields and menus in the focused window on the computer."
    @Generable struct Arguments {}
    func call(arguments: Arguments) async throws -> String { try await actions.look() }
}

struct ClickElement: Tool {
    let actions: any ComputerActions
    let name = "click_element"
    let description = "Press one of the numbered elements look_at_screen listed."
    @Generable struct Arguments {
        @Guide(description: "The element's number")
        var number: Int
    }
    func call(arguments: Arguments) async throws -> String { try await actions.click(element: arguments.number) }
}

struct ParkComputer: Tool {
    let actions: any ComputerActions
    let name = "park_computer"
    let description = "Put the computer to sleep now, keeping every open app exactly where it is."
    @Generable struct Arguments {
        @Guide(description: "Why the computer is being parked, in a few words")
        var reason: String
    }
    func call(arguments: Arguments) async throws -> String { try await actions.park() }
}

struct Delegate: Tool {
    let actions: any ComputerActions
    let name = "delegate"
    let description = "Hand a task to a capable agent that works on the computer by itself: coding, files, research, writing, multi-step work in apps. It reports back when finished."
    @Generable struct Arguments {
        @Guide(description: "A complete, self-contained description of the task for the agent")
        var task: String
        @Guide(description: "The agent's name if the user names one, otherwise empty")
        var agent: String
    }
    func call(arguments: Arguments) async throws -> String {
        try await actions.delegate(task: arguments.task, agent: arguments.agent.isEmpty ? nil : arguments.agent)
    }
}
