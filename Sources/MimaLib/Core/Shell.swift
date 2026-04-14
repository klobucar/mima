import Foundation

/// POSIX single-quote a string so it can be safely embedded in shell
/// output like `export KEY=<value>`. Every literal apostrophe is closed,
/// escaped, and reopened: `it's` becomes `'it'\''s'`.
func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
