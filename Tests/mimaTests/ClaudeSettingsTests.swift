import XCTest
import Yams
@testable import MimaLib

final class SecretMappingTests: XCTestCase {
    func testShortAndLongFormsDecode() throws {
        let yaml = """
        groups:
          agent:
            OPENAI_API_KEY: openai-key
            GH_TOKEN: {secret: gh-token, hosts: [api.github.com, uploads.github.com]}
        """
        let config = try YAMLDecoder().decode(MimaConfig.self, from: yaml)
        XCTAssertEqual(config.groups["agent"]?["OPENAI_API_KEY"], SecretMapping(secret: "openai-key"))
        XCTAssertEqual(config.groups["agent"]?["GH_TOKEN"], SecretMapping(secret: "gh-token", hosts: ["api.github.com", "uploads.github.com"]))
    }

    /// Existing configs must round-trip byte-for-byte in the short form.
    func testMappingWithoutHostsEncodesShort() throws {
        var config = MimaConfig()
        config.groups["g"] = ["K": SecretMapping(secret: "s")]
        XCTAssertEqual(try YAMLEncoder().encode(config), "groups:\n  g:\n    K: s\n")
    }

    func testLinkWithHostsPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: url) }
        let m = ConfigManager(configURL: url)
        try m.link(group: "g", envVar: "GH_TOKEN", secretName: "gh", hosts: ["api.github.com"])
        try m.link(group: "g", envVar: "PLAIN", secretName: "p")
        XCTAssertEqual(try m.getMappings(for: "g")["GH_TOKEN"]?.hosts, ["api.github.com"])
        XCTAssertEqual(try m.getSecrets(for: "g"), ["GH_TOKEN": "gh", "PLAIN": "p"])
    }
}

final class ClaudeSettingsTests: XCTestCase {
    private let mappings: [String: SecretMapping] = [
        "GH_TOKEN": SecretMapping(secret: "gh", hosts: ["api.github.com"]),
        "DATABASE_URL": SecretMapping(secret: "db"),
    ]

    func testSettingsShape() throws {
        let settings = claudeSandboxSettings(mappings: mappings)
        let sandbox = try XCTUnwrap(settings["sandbox"] as? [String: Any])
        XCTAssertEqual(sandbox["enabled"] as? Bool, true)
        XCTAssertNotNil((sandbox["network"] as? [String: Any])?["tlsTerminate"], "mask entries require tlsTerminate")
        let entries = try XCTUnwrap((sandbox["credentials"] as? [String: Any])?["envVars"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["name"] as? String, "DATABASE_URL")
        XCTAssertEqual(entries[0]["mode"] as? String, "deny")
        XCTAssertNil(entries[0]["injectHosts"])
        XCTAssertEqual(entries[1]["name"] as? String, "GH_TOKEN")
        XCTAssertEqual(entries[1]["mode"] as? String, "mask")
        XCTAssertEqual(entries[1]["injectHosts"] as? [String], ["api.github.com"])
    }

    func testDenyOnlyGroupDoesNotEnableTLSTermination() throws {
        let sandbox = try XCTUnwrap(claudeSandboxSettings(mappings: ["DB": "db"])["sandbox"] as? [String: Any])
        XCTAssertNil(sandbox["network"], "don't turn on experimental TLS termination when nothing is masked")
    }

    func testArgvInsertsSettingsAfterClaude() throws {
        let argv = try claudeArgv(["claude", "-p", "hi"], mappings: mappings)
        XCTAssertEqual(argv[0], "claude")
        XCTAssertEqual(argv[1], "--settings")
        XCTAssertEqual(Array(argv[3...]), ["-p", "hi"])
        let parsed = try JSONSerialization.jsonObject(with: Data(argv[2].utf8)) as? [String: Any]
        XCTAssertNotNil(parsed?["sandbox"])
        XCTAssertEqual(try claudeArgv(["/opt/homebrew/bin/claude"], mappings: [:])[0], "/opt/homebrew/bin/claude")
    }

    func testArgvRejectsOtherCommandsAndDuplicateSettings() {
        XCTAssertThrowsError(try claudeArgv(["npx", "claude"], mappings: mappings))
        XCTAssertThrowsError(try claudeArgv(["claude", "--settings", "x.json"], mappings: mappings))
        XCTAssertThrowsError(try claudeArgv(["claude", "--settings={}"], mappings: mappings))
    }

    func testSettingsJSONCarriesNoSecretValues() throws {
        // Only names and hosts go on the command line, which `ps` shows.
        let json = try claudeArgv(["claude"], mappings: mappings)[2]
        XCTAssertFalse(json.contains("\"gh\""))
        XCTAssertFalse(json.contains("\"db\""))
    }

    func testHostValidation() {
        for ok in ["api.github.com", "*.example.com", "a-b.c0.io"] { XCTAssertTrue(isValidInjectHost(ok), ok) }
        for bad in ["", "localhost", "https://api.github.com", "api.github.com/path", "a..b", "-a.com", "*.com", "a b.com", "*"] {
            XCTAssertFalse(isValidInjectHost(bad), bad)
        }
    }
}
