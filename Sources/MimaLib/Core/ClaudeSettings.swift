import Foundation

/// A hostname, optionally with a leading `*.` wildcard, as Claude Code's
/// sandbox network settings accept: `api.github.com`, `*.example.com`.
func isValidInjectHost(_ host: String) -> Bool {
    var labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if labels.first == "*" { labels.removeFirst() }
    guard labels.count >= 2 else { return false }
    return labels.allSatisfy { label in
        !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
            && label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}

/// Claude Code settings that keep a group's values away from sandboxed
/// Bash commands, for `claude --settings <json>`.
///
/// - With hosts: `mode: "mask"`. Sandboxed commands see a placeholder,
///   and the sandbox proxy substitutes the real value only on requests to
///   those hosts. This needs the experimental `network.tlsTerminate`.
/// - Without hosts: `mode: "deny"`. Sandboxed commands don't get the
///   variable at all.
///
/// Claude Code honors `mask` and `tlsTerminate` only from user settings,
/// managed settings, or `--settings`, never from a repo's
/// `.claude/settings*.json`. A wrapper passing `--settings` is the
/// supported way in. This covers sandboxed Bash only: the Claude process
/// itself gets the real values, and per Claude Code's docs, hooks and
/// local MCP servers run with full access.
func claudeSandboxSettings(mappings: [String: SecretMapping]) -> [String: Any] {
    let entries: [[String: Any]] = mappings.sorted(by: { $0.key < $1.key }).map { envVar, mapping in
        mapping.hosts.isEmpty
            ? ["name": envVar, "mode": "deny"]
            : ["name": envVar, "mode": "mask", "injectHosts": mapping.hosts]
    }
    var sandbox: [String: Any] = ["enabled": true, "credentials": ["envVars": entries]]
    if mappings.values.contains(where: { !$0.hosts.isEmpty }) {
        sandbox["network"] = ["tlsTerminate": [String: Any]()]
    }
    return ["sandbox": sandbox]
}

enum ClaudeWrapError: Error, CustomStringConvertible {
    case notClaude(String)
    case settingsAlreadyGiven

    var description: String {
        switch self {
        case .notClaude(let cmd):
            return "--claude needs the command to be claude, got \(cmd.debugDescription). mima inserts --settings right after it."
        case .settingsAlreadyGiven:
            return "--claude passes its own --settings; merge your settings into a file and pass it some other way (e.g. user settings)."
        }
    }
}

/// `claude <args>` → `claude --settings <json> <args>`.
func claudeArgv(_ argv: [String], mappings: [String: SecretMapping]) throws -> [String] {
    guard let first = argv.first, (first as NSString).lastPathComponent == "claude" else {
        throw ClaudeWrapError.notClaude(argv.first ?? "")
    }
    if argv.dropFirst().contains(where: { $0 == "--settings" || $0.hasPrefix("--settings=") }) {
        throw ClaudeWrapError.settingsAlreadyGiven
    }
    let json = try JSONSerialization.data(withJSONObject: claudeSandboxSettings(mappings: mappings), options: [.sortedKeys, .withoutEscapingSlashes])
    return [first, "--settings", String(decoding: json, as: UTF8.self)] + argv.dropFirst()
}
