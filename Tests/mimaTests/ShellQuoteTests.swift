import XCTest
@testable import MimaLib

final class ShellQuoteTests: XCTestCase {
    func testPlainValue() {
        XCTAssertEqual(shellSingleQuote("hello"), "'hello'")
    }

    func testEmptyValue() {
        XCTAssertEqual(shellSingleQuote(""), "''")
    }

    func testValueWithSingleQuote() {
        // it's -> 'it'\''s'
        XCTAssertEqual(shellSingleQuote("it's"), "'it'\\''s'")
    }

    func testValueWithMultipleQuotes() {
        XCTAssertEqual(shellSingleQuote("a'b'c"), "'a'\\''b'\\''c'")
    }

    func testValueWithShellMetacharacters() {
        // Inside single quotes everything except ' is literal,
        // so $ ` \ " and newlines must pass through untouched.
        XCTAssertEqual(
            shellSingleQuote("$(whoami) `id` \"x\" \\n"),
            "'$(whoami) `id` \"x\" \\n'"
        )
    }

    func testRoundTripThroughBash() throws {
        let inputs = [
            "plain",
            "with spaces",
            "it's",
            "$(whoami)",
            "`id`",
            "back\\slash",
            "quote\"inside",
            "mix'ed $VAR and `cmd`",
            "",
        ]
        for value in inputs {
            let quoted = shellSingleQuote(value)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s \(quoted)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            XCTAssertEqual(output, value, "round-trip failed for \(value.debugDescription)")
        }
    }
}
