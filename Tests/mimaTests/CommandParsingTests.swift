import ArgumentParser
import XCTest
@testable import MimaLib

/// Parse through `MimaApp.parseAsRoot` so these tests use the same
/// routing, `validate()` calls, and passthrough behaviour as the real CLI.
final class CommandParsingTests: XCTestCase {
    private func parseRun(_ args: [String]) throws -> Run {
        let command = try MimaApp.parseAsRoot(["run"] + args)
        return try XCTUnwrap(command as? Run)
    }

    // MARK: - mima run <group> -- cmd

    func testDocumentedDoubleDashFormRunsTheCommand() throws {
        XCTAssertEqual(try parseRun(["g", "--", "echo", "hi"]).childArgv, ["echo", "hi"])
    }

    func testFormWithoutDoubleDashStillWorks() throws {
        XCTAssertEqual(try parseRun(["g", "echo", "hi"]).childArgv, ["echo", "hi"])
    }

    func testOnlyLeadingDoubleDashIsStripped() throws {
        XCTAssertEqual(try parseRun(["g", "--", "cmd", "--", "x"]).childArgv, ["cmd", "--", "x"])
        XCTAssertEqual(try parseRun(["g", "cmd", "--", "x"]).childArgv, ["cmd", "--", "x"])
    }

    func testChildOptionsPassThrough() throws {
        XCTAssertEqual(
            try parseRun(["g", "--", "claude", "--model", "x", "-p"]).childArgv,
            ["claude", "--model", "x", "-p"]
        )
    }

    // MARK: - mima secret rm

    func testSecretRmAliasResolvesToRemove() throws {
        let command = try MimaApp.parseAsRoot(["secret", "rm", "openai-key"])
        let remove = try XCTUnwrap(command as? Secret.Remove)
        XCTAssertEqual(remove.name, "openai-key")
        XCTAssertNotNil(try MimaApp.parseAsRoot(["secret", "remove", "openai-key"]) as? Secret.Remove)
    }

    // MARK: - Env-var name validation at the CLI boundary

    func testGroupLinkRejectsInvalidEnvVarName() {
        XCTAssertThrowsError(
            try MimaApp.parseAsRoot(["group", "link", "agent", "X=1; touch pwned; Y", "openai-key"])
        )
        XCTAssertThrowsError(try MimaApp.parseAsRoot(["group", "link", "agent", "", "openai-key"]))
    }

    func testGroupLinkAcceptsValidEnvVarName() throws {
        XCTAssertNotNil(
            try MimaApp.parseAsRoot(["group", "link", "agent", "OPENAI_API_KEY", "openai-key"]) as? Group.Link
        )
    }

    func testSecretGetExportRejectsNameThatIsNotAnIdentifier() {
        let hostile = "a;$'\\164\\157\\165\\143\\150' pwnedget;b"
        XCTAssertThrowsError(try MimaApp.parseAsRoot(["secret", "get", hostile, "--export"]))
        // Without --export the name is never emitted as shell, so it's allowed.
        XCTAssertNoThrow(try MimaApp.parseAsRoot(["secret", "get", hostile]))
    }

    func testSecretGetExportDerivesNameFromSecretName() throws {
        XCTAssertNoThrow(try MimaApp.parseAsRoot(["secret", "get", "test-key", "--export"]))
        XCTAssertEqual(Secret.Get.exportName(for: "test-key"), "TEST_KEY")
    }
}
