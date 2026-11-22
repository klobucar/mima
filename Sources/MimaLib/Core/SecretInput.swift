import Foundation
import Darwin

enum SecretInputError: Error, CustomStringConvertible {
    case noTerminal
    case tooLong(Int)
    case empty
    case containsNUL
    case notUTF8

    var description: String {
        switch self {
        case .noTerminal:
            return "no terminal to prompt on; pipe the value in with --stdin"
        case .tooLong(let limit):
            return "value is longer than the \(limit)-byte prompt limit; pipe it in with --stdin"
        case .empty:
            return "value is empty"
        case .containsNUL:
            return "value contains a NUL byte, which can't be passed in an environment variable"
        case .notUTF8:
            return "value is not valid UTF-8, so it can't be injected as an environment variable"
        }
    }
}

/// Largest value the interactive prompt accepts. `getpass(3)` silently
/// truncated at 128 bytes, which cut long API keys short. This limit is
/// large enough for any realistic key, and longer input is an error rather
/// than a silent truncation.
let interactiveSecretLimit = 8192

/// Gets a secret's value from the argument, from stdin, or from a no-echo
/// prompt on the terminal, in that order of precedence.
func readSecretValue(prompt: String, inline: String?, fromStdin: Bool) throws -> Data {
    let data: Data
    if let inline {
        data = Data(inline.utf8)
    } else if fromStdin {
        data = stripOneTrailingNewline(FileHandle.standardInput.readDataToEndOfFile())
    } else {
        var buffer = [CChar](repeating: 0, count: interactiveSecretLimit + 1)
        defer { buffer.withUnsafeMutableBufferPointer { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
            throw SecretInputError.noTerminal
        }
        let length = strlen(buffer)
        // A full buffer means the input may have been cut off.
        guard length < interactiveSecretLimit else { throw SecretInputError.tooLong(interactiveSecretLimit) }
        data = Data(bytes: buffer, count: length)
    }
    try validateSecretValue(data)
    return data
}

/// `echo value | mima secret add x --stdin` appends one newline, which
/// isn't part of the value. Strips exactly one `\n` or `\r\n`.
func stripOneTrailingNewline(_ data: Data) -> Data {
    if data.last == UInt8(ascii: "\n") {
        let trimmed = data.dropLast()
        return trimmed.last == UInt8(ascii: "\r") ? Data(trimmed.dropLast()) : Data(trimmed)
    }
    return data
}

/// Rejects values that can't survive injection into an environment
/// variable. Otherwise a NUL would truncate the value in execve, and
/// invalid UTF-8 would make mima drop the value later.
func validateSecretValue(_ data: Data) throws {
    guard !data.isEmpty else { throw SecretInputError.empty }
    guard !data.contains(0) else { throw SecretInputError.containsNUL }
    guard String(data: data, encoding: .utf8) != nil else { throw SecretInputError.notUTF8 }
}
