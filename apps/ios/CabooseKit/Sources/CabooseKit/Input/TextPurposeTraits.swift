import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What the phone's keyboard offers for a remote text field, from the field's text-input-v3
/// content purpose (`purpose` in the display protocol's `text_input`, docs/display.md): the
/// keyboard layout, the AutoFill it asks iOS for, secure entry, and whether it types prose.
///
/// AutoFill sees only this one field. iOS cannot see the remote form or the website it
/// belongs to, so it fills one field at a time and cannot pre-suggest that site's credential;
/// the person picks it from their passwords.
public struct TextPurposeTraits: Equatable, Sendable {
    /// The iOS keyboard layout (`UIKeyboardType`).
    public enum Keyboard: Equatable, Sendable {
        case standard, numberPad, numbersAndPunctuation, phonePad, url, email
    }

    /// The AutoFill the field asks for (`UITextContentType`).
    public enum AutoFill: Equatable, Sendable {
        case username, password, oneTimeCode, telephoneNumber, url, name
    }

    public enum Capitalization: Equatable, Sendable {
        case sentences, words
    }

    /// The label on the keyboard's Return key (`UIReturnKeyType`); Return is always a real
    /// Enter key press either way.
    public enum ReturnKey: Equatable, Sendable {
        case standard, go
    }

    public var keyboard = Keyboard.standard
    public var autoFill: AutoFill?
    /// Secure entry: the keyboard learns nothing from the field and offers no predictions,
    /// dictation or third-party keyboards.
    public var secure = false
    /// Autocorrect, capitals, spell checking and inline prediction. Nil when there is no
    /// purpose to go by: the caller decides from the app (a terminal or code editor is not prose).
    public var prose: Bool?
    /// How prose is capitalized.
    public var capitalization = Capitalization.sentences
    public var returnKey = ReturnKey.standard

    /// The traits for a purpose name as the compositor sends it (`normal`, `alpha`, `digits`,
    /// `number`, `phone`, `url`, `email`, `name`, `password`, `pin`, `date`, `time`,
    /// `datetime`, `terminal`), or nil when the field reports none. A name this build does not
    /// know is treated as normal text.
    public init(purpose: String?) {
        guard let purpose else { return }
        switch purpose {
        case "password":
            autoFill = .password
            secure = true
            prose = false
        case "pin":
            // A numeric password or a code sent to the person (GTK's PIN purpose). A number
            // pad has no predictions or learning, so secure entry would add nothing, and it
            // must not stand between the field and a code iOS offers from Messages or Mail.
            keyboard = .numberPad
            autoFill = .oneTimeCode
            prose = false
        case "digits":
            // Firefox reports `inputmode="numeric"` as digits, which is how web pages mark
            // up one-time-code fields; Chromium reports those as normal text. iOS offers a
            // code only when one arrived in the last few minutes, so other digit fields
            // (quantities, postal codes) are not crowded.
            keyboard = .numberPad
            autoFill = .oneTimeCode
            prose = false
        case "number":
            // Decimal separator and sign included, which the number pad lacks.
            keyboard = .numbersAndPunctuation
            prose = false
        case "date", "time", "datetime":
            keyboard = .numbersAndPunctuation
            prose = false
        case "phone":
            keyboard = .phonePad
            autoFill = .telephoneNumber
            prose = false
        case "url":
            // Mostly a browser's address bar, which Return opens.
            keyboard = .url
            autoFill = .url
            returnKey = .go
            prose = false
        case "email":
            // An email field is almost always the account name of a login form, where
            // AutoFill matters: as a username iOS offers the saved passwords, from which
            // the person picks the site's login (the email keyboard keeps typing it quick).
            keyboard = .email
            autoFill = .username
            prose = false
        case "name":
            autoFill = .name
            capitalization = .words
            prose = true
        case "terminal":
            prose = false
        default:
            // normal and alpha: iOS has no letters-only keyboard that keeps every language.
            prose = true
        }
    }

    /// AutoFill puts one whole value here, a password or a code, replacing the field's text.
    public var fillsWholeValue: Bool {
        autoFill == .password || autoFill == .oneTimeCode
    }
}

#if canImport(UIKit)
extension TextPurposeTraits {
    var keyboardType: UIKeyboardType {
        switch keyboard {
        case .standard: .default
        case .numberPad: .numberPad
        case .numbersAndPunctuation: .numbersAndPunctuation
        case .phonePad: .phonePad
        case .url: .URL
        case .email: .emailAddress
        }
    }

    var textContentType: UITextContentType? {
        guard let autoFill else { return nil }
        let type: UITextContentType = switch autoFill {
        case .username: .username
        case .password: .password
        case .oneTimeCode: .oneTimeCode
        case .telephoneNumber: .telephoneNumber
        case .url: .URL
        case .name: .name
        }
        return type
    }

    var returnKeyType: UIReturnKeyType {
        switch returnKey {
        case .standard: .default
        case .go: .go
        }
    }
}
#endif
