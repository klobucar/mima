import XCTest
@testable import MimaLib

final class CallerChainTests: XCTestCase {
    private func chain(_ names: String...) -> [CallerProcess] {
        names.enumerated().map { CallerProcess(pid: pid_t(100 + $0.offset), name: $0.element) }
    }

    // MARK: Detection

    func testClaudeChildSessionIsAnAgent() {
        let d = detectAgent(environment: ["CLAUDE_CODE_CHILD_SESSION": "1"], chain: chain("Terminal", "zsh"))
        XCTAssertEqual(d?.agent, "Claude Code")
    }

    /// Claude Code's IDE extensions set CLAUDECODE=1 in terminals a human
    /// types into, so it must not count as an agent on its own.
    func testClaudecodeAloneIsNotAnAgent() {
        XCTAssertNil(detectAgent(environment: ["CLAUDECODE": "1"], chain: chain("Code Helper", "zsh")))
    }

    func testAgentInProcessTree() {
        XCTAssertEqual(detectAgent(environment: [:], chain: chain("Terminal", "zsh", "codex", "bash"))?.agent, "Codex")
        XCTAssertEqual(detectAgent(environment: [:], chain: chain("Terminal", "zsh", "node(claude)", "zsh"))?.agent, "Claude Code")
        XCTAssertEqual(detectAgent(environment: [:], chain: chain("Terminal", "python3(aider)", "sh"))?.agent, "aider")
    }

    func testPlainTerminalIsNotAnAgent() {
        XCTAssertNil(detectAgent(environment: [:], chain: chain("launchd-ish", "Terminal", "login", "zsh")))
    }

    func testScriptNameForNpmInstalledClaude() {
        XCTAssertEqual(scriptName("/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"), "claude")
        XCTAssertEqual(scriptName("/usr/local/bin/aider"), "aider")
        XCTAssertEqual(scriptName("/x/node_modules/some-tool/index.js"), "some-tool")
    }

    func testRealChainIsReadable() {
        let real = currentCallerChain()
        XCTAssertFalse(real.isEmpty, "the test runner always has a parent")
        XCTAssertTrue(real.allSatisfy { !$0.name.isEmpty })
    }

    // MARK: Refusal

    func testAgentIsRefusedWithoutAdvertisingForce() throws {
        let agent = AgentDetection(agent: "Claude Code", evidence: "x")
        let msg = try XCTUnwrap(secretOutputRefusal(force: false, agent: agent, chain: chain("zsh", "claude", "zsh"), stdinIsTTY: true, stderrIsTTY: true))
        XCTAssertTrue(msg.contains("AI agent"))
        XCTAssertTrue(msg.contains("mima run --scrub"))
        XCTAssertFalse(msg.contains("--force"), "don't hand the agent the bypass")
    }

    func testNoTerminalIsRefused() {
        XCTAssertNotNil(secretOutputRefusal(force: false, agent: nil, chain: [], stdinIsTTY: false, stderrIsTTY: false))
    }

    /// `eval "$(mima env g)"` has stdout on a pipe but stdin and stderr on
    /// the terminal, so it must be allowed.
    func testEvalInInteractiveShellIsAllowed() {
        XCTAssertNil(secretOutputRefusal(force: false, agent: nil, chain: chain("zsh"), stdinIsTTY: true, stderrIsTTY: true))
    }

    func testForceOverrides() {
        let agent = AgentDetection(agent: "Codex", evidence: "x")
        XCTAssertNil(secretOutputRefusal(force: true, agent: agent, chain: [], stdinIsTTY: false, stderrIsTTY: false))
    }

    // MARK: Prompt text

    func testReasonNamesSecretsAndAgent() {
        let reason = unlockReason(
            action: "give 2 secrets from group 'prod' to curl",
            secrets: ["stripe-live", "aws-prod"], chain: chain("Terminal", "zsh", "claude", "zsh"),
            agent: AgentDetection(agent: "Claude Code", evidence: "x")
        )
        XCTAssertTrue(reason.contains("(aws-prod, stripe-live)"), reason)
        XCTAssertTrue(reason.contains("AI agent (Claude Code)"), reason)
        XCTAssertTrue(reason.contains("zsh → claude → zsh → mima"), reason)
    }

    func testReasonTruncatesLongSecretLists() {
        let reason = unlockReason(action: "x", secrets: (1...9).map { "s\($0)" }, chain: [], agent: nil)
        XCTAssertTrue(reason.contains("+5 more"), reason)
    }

    /// Names come from the config file and process table, and must not be
    /// able to inject fake lines or reorder text in the system dialog.
    func testSanitizeStripsControlAndBidi() {
        let hostile = "ok\n\nmacOS update: approve\u{202E}lol\u{0007}"
        let clean = sanitizeForPrompt(hostile, limit: 100)
        XCTAssertFalse(clean.contains("\n"))
        XCTAssertFalse(clean.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x07 })
        XCTAssertEqual(sanitizeForPrompt(String(repeating: "a", count: 50), limit: 10).count, 10)
    }
}
