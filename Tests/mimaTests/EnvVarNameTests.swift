import XCTest
@testable import MimaLib

final class EnvVarNameTests: XCTestCase {
    func testValidNames() {
        for name in ["A", "_", "OPENAI_API_KEY", "a1", "_PRIVATE", "lower_case", "X9_Y8"] {
            XCTAssertTrue(isValidEnvVarName(name), name)
        }
    }

    func testInvalidNames() {
        let invalid = [
            "",                                      // empty: envp entry "=value"
            "1ABC",                                  // leading digit
            "PATH=/tmp/evil:/usr/bin",               // '=' splits envp in the wrong place
            "OPENAI_API_KEY=x; touch pwned_env; X",  // shell injection via `mima env`
            "A;$'\\164\\157\\165\\143\\150' PWNEDGET;B",  // octal escapes survive uppercasing
            "A B", "A-B", "A.B", "A\nB", "A\0B", "$(id)", "`id`",
            "ÉCLAIR",                                // non-ASCII letter
            "A\u{1B}]0;title\u{07}",                 // terminal escape sequence
        ]
        for name in invalid {
            XCTAssertFalse(isValidEnvVarName(name), name.debugDescription)
        }
    }

    func testExportLineRejectsInvalidNames() {
        XCTAssertThrowsError(try exportLine(name: "OPENAI_API_KEY=x; touch pwned_env; X", value: "v"))
        XCTAssertThrowsError(try exportLine(name: "", value: "v"))
    }

    func testExportLineFormat() throws {
        XCTAssertEqual(try exportLine(name: "KEY", value: "it's"), "export KEY='it'\\''s'")
    }

    func testInvalidNamesInMappingAreReportedSorted() {
        let mappings = ["GOOD": "s1", "B=AD": "s2", "": "s3", "ALSO_GOOD": "s4"]
        XCTAssertEqual(invalidEnvVarNames(in: mappings), ["", "B=AD"])
    }

    func testInvalidNameErrorEscapesControlCharacters() {
        let description = InvalidEnvVarName(name: "A\u{1B}[2KB").description
        XCTAssertFalse(description.contains("\u{1B}"), "raw ESC must not reach the terminal")
    }
}
