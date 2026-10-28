import AppIntents

enum CabooseScreen: String, AppEnum {
    case ask
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Caboose Screen")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.ask: "Ask Agent"]
}
struct OpenAskIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Ask Agent"
    static var openAppWhenRun = true
    @Parameter(title: "Screen") var target: CabooseScreen
    init() { target = .ask }
    @MainActor func perform() async throws -> some IntentResult {
        #if CABOOSE_APP
        let model = AppModel.shared
        model.askFocusRequested = true
        await model.wake()
        #endif
        return .result()
    }
}
