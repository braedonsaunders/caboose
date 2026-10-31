import Testing
@testable import CabooseKit

@Suite struct TextPurposeTraitsTests {
    /// Every content purpose the compositor names (guest/display/compositor/src/text_input.rs).
    static let purposes = ["normal", "alpha", "digits", "number", "phone", "url", "email", "name",
                           "password", "pin", "date", "time", "datetime", "terminal"]

    @Test func noPurposeLeavesProseToTheApp() {
        let traits = TextPurposeTraits(purpose: nil)
        #expect(traits.prose == nil)
        #expect(traits.keyboard == .standard)
        #expect(traits.autoFill == nil)
        #expect(!traits.secure)
        #expect(traits.returnKey == .standard)
    }

    @Test func proseOnlyWhereTheFieldTakesWords() {
        let notProse: Set = ["terminal", "password", "pin", "url", "email", "number", "digits", "phone",
                             "date", "time", "datetime"]
        for purpose in Self.purposes {
            #expect(TextPurposeTraits(purpose: purpose).prose == !notProse.contains(purpose), "\(purpose)")
        }
        #expect(TextPurposeTraits(purpose: "a-purpose-from-a-newer-protocol").prose == true)
    }

    @Test func passwordsAreSecureAndOfferSavedPasswords() {
        let traits = TextPurposeTraits(purpose: "password")
        #expect(traits.secure)
        #expect(traits.autoFill == .password)
        #expect(traits.keyboard == .standard)
        #expect(traits.fillsWholeValue)
        for purpose in Self.purposes where purpose != "password" {
            #expect(!TextPurposeTraits(purpose: purpose).secure, "\(purpose)")
        }
    }

    @Test func pinsAndDigitsTakeOneTimeCodesOnTheNumberPad() {
        for purpose in ["pin", "digits"] {
            let traits = TextPurposeTraits(purpose: purpose)
            #expect(traits.keyboard == .numberPad, "\(purpose)")
            #expect(traits.autoFill == .oneTimeCode, "\(purpose)")
            #expect(traits.fillsWholeValue, "\(purpose)")
        }
    }

    @Test func numbersAndDatesKeepSignsAndSeparators() {
        for purpose in ["number", "date", "time", "datetime"] {
            let traits = TextPurposeTraits(purpose: purpose)
            #expect(traits.keyboard == .numbersAndPunctuation, "\(purpose)")
            #expect(traits.autoFill == nil, "\(purpose)")
        }
    }

    @Test func emailIsTheLoginsUsername() {
        let traits = TextPurposeTraits(purpose: "email")
        #expect(traits.keyboard == .email)
        #expect(traits.autoFill == .username)
        #expect(!traits.fillsWholeValue)
    }

    @Test func phoneUrlAndNameOfferTheirAutoFill() {
        #expect(TextPurposeTraits(purpose: "phone").keyboard == .phonePad)
        #expect(TextPurposeTraits(purpose: "phone").autoFill == .telephoneNumber)
        let url = TextPurposeTraits(purpose: "url")
        #expect(url.keyboard == .url)
        #expect(url.autoFill == .url)
        #expect(url.returnKey == .go)
        let name = TextPurposeTraits(purpose: "name")
        #expect(name.autoFill == .name)
        #expect(name.capitalization == .words)
        #expect(name.prose == true)
    }

    @Test func plainTextAndTerminalsAskForNoAutoFill() {
        for purpose in ["normal", "alpha", "terminal"] {
            let traits = TextPurposeTraits(purpose: purpose)
            #expect(traits.keyboard == .standard, "\(purpose)")
            #expect(traits.autoFill == nil, "\(purpose)")
            #expect(traits.capitalization == .sentences, "\(purpose)")
            #expect(traits.returnKey == .standard, "\(purpose)")
        }
    }

    @Test func onlyPasswordsAndCodesAreFilledWhole() {
        let whole = Self.purposes.filter { TextPurposeTraits(purpose: $0).fillsWholeValue }
        #expect(whole == ["digits", "password", "pin"])
    }
}
