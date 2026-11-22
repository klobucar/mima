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

    // MARK: - mima run --scrub / --keep

    func testScrubFlagBeforeGroup() throws {
        let run = try parseRun(["--scrub", "g", "--", "claude"])
        XCTAssertTrue(run.scrub)
        XCTAssertEqual(run.group, "g")
        XCTAssertEqual(run.childArgv, ["claude"])
    }

    func testScrubIsOffByDefault() throws {
        XCTAssertFalse(try parseRun(["g", "--", "claude"]).scrub)
    }

    func testKeepIsRepeatable() throws {
        let run = try parseRun(["--scrub", "--keep", "SSH_AUTH_SOCK", "--keep", "EDITOR", "g", "--", "claude"])
        XCTAssertEqual(run.keep, ["SSH_AUTH_SOCK", "EDITOR"])
    }

    func testKeepWithoutScrubIsRejected() {
        XCTAssertThrowsError(try parseRun(["--keep", "EDITOR", "g", "--", "claude"]))
    }

    func testKeepRejectsInvalidName() {
        XCTAssertThrowsError(try parseRun(["--scrub", "--keep", "A=B", "g", "--", "claude"]))
    }

    /// `mima run g --scrub -- cmd` would otherwise exec "--scrub" and the
    /// user would believe the child was scrubbed.
    func testScrubAfterGroupIsAnErrorNotACommand() {
        XCTAssertThrowsError(try parseRun(["g", "--scrub", "--", "claude"]))
        XCTAssertThrowsError(try parseRun(["g", "--", "--scrub", "claude"]))
        XCTAssertThrowsError(try parseRun(["g", "--keep=X", "claude"]))
    }

    // MARK: - mima secret rm

    func testSecretRmAliasResolvesToRemove() throws {
        let command = try MimaApp.parseAsRoot(["secret", "rm", "openai-key"])
        let remove = try XCTUnwrap(command as? Secret.Remove)
        XCTAssertEqual(remove.name, "openai-key")
        XCTAssertNotNil(try MimaApp.parseAsRoot(["secret", "remove", "openai-key"]) as? Secret.Remove)
    }

    // MARK: - Lifecycle commands

    func testSecretAddStdinAndValueAreExclusive() {
        XCTAssertNoThrow(try MimaApp.parseAsRoot(["secret", "add", "k", "--stdin"]))
        XCTAssertThrowsError(try MimaApp.parseAsRoot(["secret", "add", "k", "v", "--stdin"]))
    }

    func testSecretUpdateParses() throws {
        let update = try XCTUnwrap(MimaApp.parseAsRoot(["secret", "update", "k", "--stdin"]) as? Secret.Update)
        XCTAssertTrue(update.stdin)
    }

    func testGroupUnlinkAndRemove() throws {
        XCTAssertNotNil(try MimaApp.parseAsRoot(["group", "unlink", "g", "VAR"]) as? Group.Unlink)
        XCTAssertNotNil(try MimaApp.parseAsRoot(["group", "rm", "g"]) as? Group.Remove)
        XCTAssertNotNil(try MimaApp.parseAsRoot(["group", "remove", "g"]) as? Group.Remove)
    }

    func testImportRequiresGroup() throws {
        XCTAssertThrowsError(try MimaApp.parseAsRoot(["import", ".env"]))
        let cmd = try XCTUnwrap(MimaApp.parseAsRoot(["import", ".env", "--group", "app", "--overwrite"]) as? Import)
        XCTAssertEqual(cmd.group, "app")
        XCTAssertTrue(cmd.overwrite)
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
