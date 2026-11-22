import XCTest
@testable import MimaLib

final class ChildEnvironmentTests: XCTestCase {
    private let parent = [
        "PATH": "/usr/bin:/bin",
        "HOME": "/Users/me",
        "USER": "me",
        "LOGNAME": "me",
        "SHELL": "/bin/zsh",
        "TERM": "xterm-256color",
        "TMPDIR": "/var/folders/xx/T/",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "LC_CTYPE": "UTF-8",
        "TZ": "America/Vancouver",
        "AWS_SECRET_ACCESS_KEY": "prod-key-from-zshenv",
        "GITHUB_TOKEN": "personal-token",
        "SSH_AUTH_SOCK": "/Users/me/.paprika/agent.sock",
        "OPENAI_API_KEY": "stale-shell-value",
    ]
    private let secrets = ["OPENAI_API_KEY": "group-value", "ANTHROPIC_API_KEY": "group-anthropic"]

    func testInheritModePassesParentAndSecrets() {
        let env = buildChildEnvironment(parent: parent, secrets: secrets, scrub: false)
        XCTAssertEqual(env["AWS_SECRET_ACCESS_KEY"], "prod-key-from-zshenv")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "group-anthropic")
        XCTAssertEqual(env["OPENAI_API_KEY"], "group-value", "group secret must win over the parent value")
    }

    func testScrubDropsEverythingOutsideSafelist() {
        let env = buildChildEnvironment(parent: parent, secrets: secrets, scrub: true)
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(env["GITHUB_TOKEN"])
        XCTAssertNil(env["SSH_AUTH_SOCK"], "SSH agent access must not reach a scrubbed child by default")
        XCTAssertEqual(
            Set(env.keys),
            ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
             "OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
        )
    }

    func testScrubStillInjectsSecretsAndPrefersThem() {
        let env = buildChildEnvironment(parent: parent, secrets: secrets, scrub: true)
        XCTAssertEqual(env["OPENAI_API_KEY"], "group-value")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "group-anthropic")
    }

    func testKeepAddsNamedVariables() {
        let env = buildChildEnvironment(parent: parent, secrets: [:], scrub: true, keep: ["SSH_AUTH_SOCK"])
        XCTAssertEqual(env["SSH_AUTH_SOCK"], "/Users/me/.paprika/agent.sock")
        XCTAssertNil(env["GITHUB_TOKEN"])
    }

    func testKeepOfMissingVariableIsHarmless() {
        let env = buildChildEnvironment(parent: parent, secrets: [:], scrub: true, keep: ["NOT_SET_ANYWHERE"])
        XCTAssertNil(env["NOT_SET_ANYWHERE"])
    }

    func testSafelistDoesNotMatchPrefixesOtherThanLC() {
        let env = buildChildEnvironment(parent: ["PATHOLOGICAL": "x", "HOME_DIR": "y", "LC_TIME": "z"], secrets: [:], scrub: true)
        XCTAssertEqual(Set(env.keys), ["LC_TIME"])
    }
}
