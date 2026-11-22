import Foundation

/// POSIX single-quote a string so it can be safely embedded in shell
/// output like `export KEY=<value>`. Every literal apostrophe is closed,
/// escaped, and reopened: `it's` becomes `'it'\''s'`.
///
/// This walks Unicode scalars, not `Character`s. Swift compares
/// `Character`s by grapheme cluster, so an apostrophe followed by a
/// combining mark (U+0300) or variation selector (U+FE0F) is a single
/// `Character` that is not equal to `"'"`. A `Character`-level replace
/// therefore skips it, and the raw 0x27 byte closes the quote in the
/// shell. Matching on scalars guarantees every 0x27 byte is escaped.
func shellSingleQuote(_ value: String) -> String {
    var out = String.UnicodeScalarView()
    out.append("'")
    for scalar in value.unicodeScalars {
        if scalar == "'" {
            out.append(contentsOf: "'\\''".unicodeScalars)
        } else {
            out.append(scalar)
        }
    }
    out.append("'")
    return String(out)
}

/// Thrown when a name would be emitted as an environment variable but
/// is not a valid identifier.
struct InvalidEnvVarName: Error, CustomStringConvertible {
    let name: String
    var description: String {
        // debugDescription escapes control characters, so a hostile name
        // can't inject terminal escape sequences into the error message.
        "invalid environment variable name \(name.debugDescription): use letters, digits, and underscores, not starting with a digit"
    }
}

/// True if `name` is a portable environment variable name: an ASCII
/// letter or underscore, followed by ASCII letters, digits, or
/// underscores. This is the POSIX rule for names a shell can assign.
///
/// Anything else is unsafe. `export NAME=...` emits the name unquoted, so
/// a name can contain shell syntax. In an execve envp, a name with `=` in
/// it splits in the wrong place.
func isValidEnvVarName(_ name: String) -> Bool {
    func isAlphaOrUnderscore(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || b == UInt8(ascii: "_")
    }
    func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }

    let bytes = name.utf8
    guard let first = bytes.first, isAlphaOrUnderscore(first) else { return false }
    return bytes.allSatisfy { isAlphaOrUnderscore($0) || isDigit($0) }
}

/// Returns the env-var names in a group mapping that fail
/// `isValidEnvVarName`, sorted so error output is stable.
func invalidEnvVarNames(in mappings: [String: String]) -> [String] {
    mappings.keys.filter { !isValidEnvVarName($0) }.sorted()
}

/// Renders one `export NAME='value'` line for `eval`. Throws if the name
/// is not a valid identifier, because the name is emitted unquoted.
func exportLine(name: String, value: String) throws -> String {
    guard isValidEnvVarName(name) else { throw InvalidEnvVarName(name: name) }
    return "export \(name)=\(shellSingleQuote(value))"
}
