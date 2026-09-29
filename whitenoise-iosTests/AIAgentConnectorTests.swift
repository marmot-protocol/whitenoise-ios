import Foundation
import Testing
@testable import whitenoise_ios

struct AIAgentConnectorTests {
    @Test func listsAllSixConnectorsInOrder() {
        #expect(AIAgentConnector.allCases == [.hermes, .openclaw, .opencode, .codex, .claude, .pi])
    }

    @Test(arguments: [
        (AIAgentConnector.codex, "codex", "wn-codex"),
        (AIAgentConnector.claude, "claude", "wn-claude"),
        (AIAgentConnector.pi, "pi", "wn-pi")
    ])
    func harnessPromptsPointAtTheirOwnGuideInstallerAndBinary(connector: AIAgentConnector, harness: String, binary: String) {
        let npub = "npub1testconnector"
        let prompt = connector.prompt(npub: npub)
        #expect(prompt.contains(npub))
        #expect(prompt.contains("integrations/\(harness)/marmot/README.md"))
        #expect(prompt.contains("install-\(harness)-marmot.sh"))
        #expect(prompt.contains("\(binary) --version"))
        #expect(!connector.name.isEmpty)
        #expect(!connector.subtitle.isEmpty)
    }
}
