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

    // MARK: - Grapheme-cluster bypass (found by differential fuzzing)
    //
    // An apostrophe followed by a combining mark or variation selector is
    // one Swift `Character` that is not equal to "'". A Character-level
    // replace skipped it, so the raw quote byte closed the shell string
    // and the rest of the value ran as shell code.

    private static let graphemeExploits: [String] = [
        "sk-real'\u{0300}; touch pwned; #",    // combining grave accent
        "sk-real'\u{FE0F}; touch pwned; #",    // emoji variation selector
        "sk-real'\u{200D}; touch pwned; #",    // zero-width joiner
        "sk-real'\u{1F3FB}; touch pwned; #",   // emoji skin-tone modifier
        "sk-real\u{0600}'; touch pwned; #",    // prepend char before the quote
        "x'\u{0301}$(touch pwned)'\u{0301}",
    ]

    func testGraphemeJoinedApostrophesAreEscaped() {
        for value in Self.graphemeExploits {
            XCTAssertFalse(
                hasUnescapedQuote(shellSingleQuote(value)),
                "raw apostrophe leaked for \(value.debugDescription)"
            )
        }
    }

    /// End-to-end version of the original exploit. Each payload is
    /// eval'd as an `export` line in every shell `mima env` users are
    /// likely to have. The payload must not run, and the value must
    /// come back unchanged.
    func testExportLineDoesNotExecuteInAnyShell() throws {
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertFalse(shells.isEmpty)

        for shell in shells {
            for value in Self.graphemeExploits {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mima-quote-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-c", #"eval "$LINE"; printf %s "$OPENAI_API_KEY""#]
                process.currentDirectoryURL = dir
                process.environment = [
                    "LINE": try exportLine(name: "OPENAI_API_KEY", value: value),
                    "PATH": "/usr/bin:/bin",
                    "LC_ALL": "en_US.UTF-8",
                ]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)

                let pwned = FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned").path)
                XCTAssertFalse(pwned, "\(shell) executed payload in \(value.debugDescription)")
                XCTAssertEqual(output, value, "\(shell) round-trip failed for \(value.debugDescription)")
            }
        }
    }

    /// Seeded property test: in random strings that mix apostrophes,
    /// grapheme extenders, and ASCII, every 0x27 byte in the output must
    /// come from the quoting itself. The pre-fix implementation failed on
    /// about 39% of these inputs.
    func testRandomizedNoUnescapedQuotes() {
        let extenders: [Unicode.Scalar] =
            (0x300...0x36F).compactMap(Unicode.Scalar.init)
            + [0x200C, 0x200D, 0xFE00, 0xFE0F, 0x1F3FB, 0x0903, 0x093F, 0x0600,
               0x0E33, 0x1160, 0x11A8, 0x20E3, 0xE0001].compactMap(Unicode.Scalar.init)
        var rng = SplitMix64(seed: 0x6D696D61)  // "mima"
        for _ in 0..<20_000 {
            var scalars = String.UnicodeScalarView()
            for _ in 0..<Int.random(in: 1...12, using: &rng) {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: scalars.append("'")
                case 1: scalars.append(extenders.randomElement(using: &rng)!)
                default: scalars.append(Unicode.Scalar(UInt8.random(in: 0x20...0x7E, using: &rng)))
                }
            }
            let value = String(scalars)
            XCTAssertFalse(hasUnescapedQuote(shellSingleQuote(value)), "leak for \(value.debugDescription)")
        }
    }

    /// True if, after removing the outer quotes, the bytes contain an
    /// apostrophe that is not part of an `'\''` escape sequence.
    private func hasUnescapedQuote(_ quoted: String) -> Bool {
        var bytes = Array(quoted.utf8)
        guard bytes.first == 0x27, bytes.last == 0x27, bytes.count >= 2 else { return true }
        bytes.removeFirst()
        bytes.removeLast()
        let escape = Array("'\\''".utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x27 {
                guard bytes[i..<min(bytes.count, i + 4)].elementsEqual(escape) else { return true }
                i += 4
            } else {
                i += 1
            }
        }
        return false
    }
}

/// Small seedable PRNG so the randomized tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
