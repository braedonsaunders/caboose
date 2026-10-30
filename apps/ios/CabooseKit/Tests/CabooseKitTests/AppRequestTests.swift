import Testing
@testable import CabooseKit

@Suite struct AppRequestTests {
    @Test func trimsAndValidates() {
        #expect(AppRequest("  a habit tracker \n").description == "a habit tracker")
        #expect(AppRequest("a habit tracker").isValid)
        #expect(!AppRequest(" \n\t").isValid)
        #expect(AppRequest(String(repeating: "x", count: AppRequest.maxLength)).isValid)
        #expect(!AppRequest(String(repeating: "x", count: AppRequest.maxLength + 1)).isValid)
    }

    @Test func promptAsksForAPublishedApp() {
        let prompt = AppRequest("a timer for my sourdough").prompt
        #expect(prompt.hasPrefix("Make me a Caboose app: a timer for my sourdough\n\n"))
        for step in ["app_guide", "app_publish", "app_open"] { #expect(prompt.contains(step)) }
        for check in ["primary action", "text entry", "scrolling", "saved-state reload",
                      "test-owned data", "preserve existing app data", "phone touch checks you could not run"] {
            #expect(prompt.contains(check))
        }
        #expect(!prompt.contains("\\"))
    }
}
