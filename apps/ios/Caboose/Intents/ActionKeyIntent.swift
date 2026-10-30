import AppIntents
import Foundation

/// The Action button, or any shortcut, as a key on the computer: a press and release of the
/// computer's `KEY_PROG1` through the phone's buttons device (docs/devices.md).
struct PressComputerActionKeyIntent: AppIntent {
    static var title: LocalizedStringResource = "Press Computer Action Key"
    static var description = IntentDescription("Press the Action key of the computer Caboose is showing. Assign it to the Action button to use the button in Linux apps.")

    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case notConnected
        var localizedStringResource: LocalizedStringResource {
            "Open your computer in Caboose, with Buttons on in its hardware settings, to press its Action key."
        }
    }

    @MainActor func perform() async throws -> some IntentResult {
        guard AppModel.shared.devices.pressAction() else { throw Failure.notConnected }
        return .result()
    }
}
