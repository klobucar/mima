import Foundation

struct DotEnvError: Error, CustomStringConvertible, Equatable {
    let line: Int
    let message: String
    var description: String { "line \(line): \(message)" }
}

/// Parses a `.env` file into (key, value) pairs in file order. If a key
/// repeats, the last value wins, matching common dotenv loaders.
///
/// Supported syntax:
/// - `KEY=value`, `export KEY=value`, and blank or `#` comment lines.
/// - Unquoted values: trimmed. ` #` starts an inline comment.
/// - `'single quoted'` values: literal, and may span lines.
/// - `"double quoted"` values: may span lines. `\n \r \t \" \\ \$` are
///   escapes; any other backslash is kept as is.
///
/// There is no variable expansion: `${OTHER}` stays literal. Expanding it
/// would mean reading the current environment and mixing those values
/// into stored secrets.
func parseDotEnv(_ text: String) throws -> [(key: String, value: String)] {
    let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars)
    var i = 0
    var line = 1
    var order: [String] = []
    var values: [String: String] = [:]

    func peek() -> Unicode.Scalar? { i < chars.count ? chars[i] : nil }
    func skip(while pred: (Unicode.Scalar) -> Bool) {
        while let c = peek(), pred(c) { i += 1 }
    }
    func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }
    func skipRestOfLine() {
        while let c = peek(), c != "\n" { i += 1 }
    }
    // After a closing quote, only blanks or a comment may follow.
    func expectEndOfValue() throws {
        skip(while: isBlank)
        if let c = peek(), c != "\n", c != "#" {
            throw DotEnvError(line: line, message: "unexpected text after closing quote")
        }
        skipRestOfLine()
    }

    while i < chars.count {
        skip(while: isBlank)
        guard let c = peek() else { break }
        if c == "\n" { i += 1; line += 1; continue }
        if c == "#" { skipRestOfLine(); continue }

        let startLine = line
        // Key, optionally preceded by `export `.
        var keyScalars = String.UnicodeScalarView()
        while let c = peek(), c != "=", c != "\n" { keyScalars.append(c); i += 1 }
        var key = String(keyScalars).trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("export ") || key.hasPrefix("export\t") {
            key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard peek() == "=" else { throw DotEnvError(line: startLine, message: "expected KEY=VALUE") }
        guard isValidEnvVarName(key) else {
            throw DotEnvError(line: startLine, message: "invalid variable name \(key.debugDescription)")
        }
        i += 1  // '='
        skip(while: isBlank)

        var value = String.UnicodeScalarView()
        switch peek() {
        case "'":
            i += 1
            while true {
                guard let c = peek() else { throw DotEnvError(line: startLine, message: "unterminated single quote") }
                i += 1
                if c == "'" { break }
                if c == "\n" { line += 1 }
                value.append(c)
            }
            try expectEndOfValue()
        case "\"":
            i += 1
            while true {
                guard let c = peek() else { throw DotEnvError(line: startLine, message: "unterminated double quote") }
                i += 1
                if c == "\"" { break }
                if c == "\n" { line += 1 }
                if c == "\\", let next = peek() {
                    i += 1
                    switch next {
                    case "n": value.append("\n")
                    case "r": value.append("\r")
                    case "t": value.append("\t")
                    case "\"", "\\", "$": value.append(next)
                    default: value.append("\\"); value.append(next)
                    }
                    if next == "\n" { line += 1 }
                } else {
                    value.append(c)
                }
            }
            try expectEndOfValue()
        default:
            var raw = String.UnicodeScalarView()
            var previous: Unicode.Scalar = " "
            while let c = peek(), c != "\n" {
                if c == "#" && isBlank(previous) { skipRestOfLine(); break }
                raw.append(c); previous = c; i += 1
            }
            value = String(raw).trimmingCharacters(in: .whitespaces).unicodeScalars
        }

        if values[key] == nil { order.append(key) }
        values[key] = String(value)

    }
    return order.map { ($0, values[$0]!) }
}
