import XCTest
@testable import MimaLib

final class DotEnvTests: XCTestCase {
    private func parse(_ text: String) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try parseDotEnv(text).map { ($0.key, $0.value) })
    }

    func testBasicForms() throws {
        let env = try parse("""
        # comment
        A=1
        export B=two
          C = spaced value
        EMPTY=

        """)
        XCTAssertEqual(env, ["A": "1", "B": "two", "C": "spaced value", "EMPTY": ""])
    }

    func testOrderIsPreservedAndLastValueWins() throws {
        let pairs = try parseDotEnv("B=1\nA=2\nB=3\n")
        XCTAssertEqual(pairs.map(\.key), ["B", "A"])
        XCTAssertEqual(pairs.first?.value, "3")
    }

    func testInlineCommentNeedsPrecedingWhitespace() throws {
        let env = try parse("URL=https://x.test/#frag\nK=v # note\nH=a#b\n")
        XCTAssertEqual(env["URL"], "https://x.test/#frag")
        XCTAssertEqual(env["K"], "v")
        XCTAssertEqual(env["H"], "a#b")
    }

    func testSingleQuotesAreLiteral() throws {
        let env = try parse(#"K='a "b" \n $X # not a comment'"#)
        XCTAssertEqual(env["K"], #"a "b" \n $X # not a comment"#)
    }

    func testDoubleQuoteEscapes() throws {
        let env = try parse(#"K="line1\nline2\t\"q\" \\ \$HOME \x""#)
        XCTAssertEqual(env["K"], "line1\nline2\t\"q\" \\ $HOME \\x")
    }

    func testMultilineQuotedValue() throws {
        let env = try parse("KEY=\"-----BEGIN KEY-----\nabc\n-----END KEY-----\"\nNEXT=1\n")
        XCTAssertEqual(env["KEY"], "-----BEGIN KEY-----\nabc\n-----END KEY-----")
        XCTAssertEqual(env["NEXT"], "1")
    }

    func testNoVariableExpansion() throws {
        XCTAssertEqual(try parse("A=1\nB=${A}\n")["B"], "${A}")
    }

    func testCRLF() throws {
        XCTAssertEqual(try parse("A=1\r\nB='2'\r\n"), ["A": "1", "B": "2"])
    }

    func testErrorsCarryLineNumbers() {
        XCTAssertThrowsError(try parseDotEnv("A=1\nNOEQUALS\n")) { XCTAssertEqual(($0 as? DotEnvError)?.line, 2) }
        XCTAssertThrowsError(try parseDotEnv("A=1\n\nB='open\n")) { XCTAssertEqual(($0 as? DotEnvError)?.line, 3) }
        XCTAssertThrowsError(try parseDotEnv("X=\"a\" trailing\n"))
    }

    /// Names from a .env file become shell-exported names, so the same
    /// validation applies as for `group link`.
    func testRejectsUnsafeNames() {
        XCTAssertThrowsError(try parseDotEnv("A;touch pwned;B=1\n"))
        XCTAssertThrowsError(try parseDotEnv("1A=1\n"))
    }
}

final class SecretInputTests: XCTestCase {
    func testStripsExactlyOneTrailingNewline() {
        XCTAssertEqual(stripOneTrailingNewline(Data("v\n".utf8)), Data("v".utf8))
        XCTAssertEqual(stripOneTrailingNewline(Data("v\r\n".utf8)), Data("v".utf8))
        XCTAssertEqual(stripOneTrailingNewline(Data("v\n\n".utf8)), Data("v\n".utf8))
        XCTAssertEqual(stripOneTrailingNewline(Data("v".utf8)), Data("v".utf8))
    }

    func testRejectsValuesThatCantBeEnvVars() {
        XCTAssertThrowsError(try validateSecretValue(Data()))
        XCTAssertThrowsError(try validateSecretValue(Data([0x61, 0x00, 0x62])))
        XCTAssertThrowsError(try validateSecretValue(Data([0xFF, 0xFE])))
        XCTAssertNoThrow(try validateSecretValue(Data(String(repeating: "k", count: 200).utf8)))
    }

    func testInlineValueIsUsedVerbatim() throws {
        let long = "sk-proj-" + String(repeating: "x", count: 156)  // longer than getpass's 128-byte cap
        XCTAssertEqual(try readSecretValue(prompt: "", inline: long, fromStdin: false), Data(long.utf8))
    }
}

final class DotEnvImportTests: XCTestCase {
    private var configURL: URL!
    private var config: ConfigManager!

    override func setUp() {
        super.setUp()
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).yaml")
        config = ConfigManager(configURL: configURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: configURL)
        super.tearDown()
    }

    func testSecretNaming() {
        XCTAssertEqual(importedSecretName(prefix: "myapp", envVar: "STRIPE_KEY"), "myapp-stripe-key")
    }

    func testImportsAndLinks() throws {
        let keychain = MockKeychain()
        let results = try importDotEnv(
            [("STRIPE_KEY", "sk_test_1"), ("DATABASE_URL", "postgres://x")],
            group: "app", prefix: "app", overwrite: false, keychain: keychain, config: config
        )
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        XCTAssertEqual(keychain.items["app-stripe-key"], Data("sk_test_1".utf8))
        XCTAssertEqual(try config.getSecrets(for: "app"), ["STRIPE_KEY": "app-stripe-key", "DATABASE_URL": "app-database-url"])
    }

    func testExistingSecretIsSkippedUnlessOverwrite() throws {
        let keychain = MockKeychain()
        keychain.items["app-k"] = Data("old".utf8)

        let skipped = try importDotEnv([("K", "new")], group: "app", prefix: "app", overwrite: false, keychain: keychain, config: config)
        XCTAssertEqual(skipped.first?.status, .skippedExisting)
        XCTAssertEqual(keychain.items["app-k"], Data("old".utf8))
        XCTAssertTrue(try config.getSecrets(for: "app").isEmpty, "a skipped variable must not be linked")

        let replaced = try importDotEnv([("K", "new")], group: "app", prefix: "app", overwrite: true, keychain: keychain, config: config)
        XCTAssertEqual(replaced.first?.status, .updated)
        XCTAssertEqual(keychain.items["app-k"], Data("new".utf8))
    }

    func testFailedValueIsNotLinked() throws {
        let results = try importDotEnv([("EMPTY", "")], group: "app", prefix: "app", overwrite: false, keychain: MockKeychain(), config: config)
        guard case .failed = results.first?.status else { return XCTFail("empty value should fail") }
        XCTAssertTrue(try config.getSecrets(for: "app").isEmpty)
    }
}
