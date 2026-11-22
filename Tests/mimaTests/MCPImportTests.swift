import XCTest
@testable import MimaLib

final class MCPImportTests: XCTestCase {
    private let mima = "/usr/local/bin/mima"

    private func json(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
    }

    private func plan(_ config: [String: Any], all: Bool = false, scrub: Bool = false, taken: Set<String> = []) -> [MCPServerPlan] {
        var taken = taken
        return planMCPImport(config: config, mimaPath: mima, all: all, scrub: scrub, takenGroups: &taken)
    }

    private let desktop = """
    {"mcpServers": {
      "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                 "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_live", "LOG_LEVEL": "debug"}},
      "postgres": {"command": "uvx", "args": ["mcp-postgres"], "env": {"DATABASE_URL": "postgres://u:hunter2@db/x"}},
      "remote": {"type": "http", "url": "https://mcp.example.com", "env": {"API_KEY": "x"}},
      "wrapped": {"command": "/usr/local/bin/mima", "args": ["run", "mcp-x", "--", "y"], "env": {"API_KEY": "x"}},
      "ref": {"command": "node", "env": {"API_KEY": "${API_KEY}"}},
      "noenv": {"command": "node"}
    }}
    """

    func testPlansOnlyStdioServersWithLiteralCredentials() {
        let plans = plan(json(desktop))
        XCTAssertEqual(plans.map(\.server), ["github", "postgres"])
    }

    func testGithubPlan() throws {
        let gh = try XCTUnwrap(plan(json(desktop)).first { $0.server == "github" })
        XCTAssertEqual(gh.group, "mcp-github")
        XCTAssertEqual(gh.moves, [MCPMove(envVar: "GITHUB_PERSONAL_ACCESS_TOKEN", secretName: "mcp-github-github-personal-access-token")])
        XCTAssertEqual(gh.keptEnv, ["LOG_LEVEL"])
        XCTAssertEqual(gh.newCommand, mima)
        XCTAssertEqual(gh.newArgs, ["run", "mcp-github", "--", "npx", "-y", "@modelcontextprotocol/server-github"])
    }

    func testCredentialURLIsDetectedByValue() throws {
        let pg = try XCTUnwrap(plan(json(desktop)).first { $0.server == "postgres" })
        XCTAssertEqual(pg.moves.map(\.envVar), ["DATABASE_URL"])
    }

    func testAllMovesEveryLiteral() throws {
        let gh = try XCTUnwrap(plan(json(desktop), all: true).first { $0.server == "github" })
        XCTAssertEqual(Set(gh.moves.map(\.envVar)), ["GITHUB_PERSONAL_ACCESS_TOKEN", "LOG_LEVEL"])
    }

    /// With --scrub, mima would strip variables the client still passes from
    /// the config's env, so each must be kept explicitly.
    func testScrubKeepsRemainingConfigEnv() throws {
        let gh = try XCTUnwrap(plan(json(desktop), scrub: true).first { $0.server == "github" })
        XCTAssertEqual(Array(gh.newArgs.prefix(5)), ["run", "--scrub", "--keep", "LOG_LEVEL", "mcp-github"])
    }

    func testClaudeCodeProjectServersAndGroupCollisions() {
        let config = json("""
        {"mcpServers": {"github": {"command": "npx", "env": {"GITHUB_TOKEN": "a"}}},
         "projects": {"/work/app": {"mcpServers": {"github": {"command": "npx", "env": {"GITHUB_TOKEN": "b"}}}}}}
        """)
        let plans = plan(config, taken: ["mcp-github-2"])
        XCTAssertEqual(plans.map(\.group), ["mcp-github", "mcp-github-3"])
        XCTAssertEqual(plans[1].keyPath, ["projects", "/work/app", "mcpServers", "github"])
        XCTAssertEqual(mcpPlanValues(plans[1], config: config), ["GITHUB_TOKEN": "b"])
    }

    func testApplyRewritesOnlyPlannedServers() throws {
        let config = json(desktop)
        let rewritten = applyMCPPlans(plan(config), to: config)
        let servers = try XCTUnwrap(rewritten["mcpServers"] as? [String: Any])
        let gh = try XCTUnwrap(servers["github"] as? [String: Any])
        XCTAssertEqual(gh["command"] as? String, mima)
        XCTAssertEqual(gh["env"] as? [String: String], ["LOG_LEVEL": "debug"], "credential removed, other env kept")
        let pg = try XCTUnwrap(servers["postgres"] as? [String: Any])
        XCTAssertNil(pg["env"], "an emptied env block is removed")
        XCTAssertEqual((servers["remote"] as? [String: Any])?["url"] as? String, "https://mcp.example.com")
        XCTAssertEqual((servers["ref"] as? [String: Any])?["env"] as? [String: String], ["API_KEY": "${API_KEY}"])
    }

    func testRewrittenConfigContainsNoMovedValues() throws {
        let config = json(desktop)
        let data = try JSONSerialization.data(withJSONObject: applyMCPPlans(plan(config), to: config))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("ghp_live"))
        XCTAssertFalse(text.contains("hunter2"))
    }

    func testSecretHeuristic() {
        for name in ["OPENAI_API_KEY", "GITHUB_PERSONAL_ACCESS_TOKEN", "DB_PASSWORD", "AWS_SECRET_ACCESS_KEY", "SLACK_BOT_TOKEN", "GH_PAT"] {
            XCTAssertTrue(looksLikeSecret(name: name, value: "x"), name)
        }
        for name in ["LOG_LEVEL", "NODE_ENV", "KEYBOARD_LAYOUT", "PORT"] {
            XCTAssertFalse(looksLikeSecret(name: name, value: "x"), name)
        }
        XCTAssertTrue(looksLikeSecret(name: "REDIS_URL", value: "redis://:pw@host:6379"))
        XCTAssertFalse(looksLikeSecret(name: "API_BASE", value: "https://api.example.com/v1"))
    }

    func testSlug() {
        XCTAssertEqual(slug("My Server (prod)!"), "my-server-prod")
        XCTAssertEqual(slug("GITHUB_TOKEN"), "github-token")
    }
}
