import Foundation

/// A known MCP client config file.
struct MCPConfigLocation: Equatable {
    let path: String
    let label: String
    /// Processes that keep this file in memory and would write the old
    /// plaintext back if they're running during the rewrite.
    let ownerProcesses: [String]
}

func defaultMCPConfigLocations(home: String, cwd: String) -> [MCPConfigLocation] {
    [
        MCPConfigLocation(path: "\(home)/.claude.json", label: "Claude Code (user and per-project)", ownerProcesses: ["claude"]),
        MCPConfigLocation(path: "\(cwd)/.mcp.json", label: "project .mcp.json", ownerProcesses: ["claude"]),
        MCPConfigLocation(
            path: "\(home)/Library/Application Support/Claude/claude_desktop_config.json",
            label: "Claude Desktop", ownerProcesses: ["Claude"]
        ),
        MCPConfigLocation(path: "\(home)/.cursor/mcp.json", label: "Cursor", ownerProcesses: ["Cursor"]),
    ]
}

struct MCPMove: Equatable {
    let envVar: String
    let secretName: String
}

/// What `mcp import` will do to one stdio MCP server entry.
struct MCPServerPlan: Equatable {
    /// JSON key path to the server object, e.g. ["mcpServers", "github"].
    let keyPath: [String]
    let server: String
    let group: String
    let moves: [MCPMove]
    let newCommand: String
    let newArgs: [String]
    /// Variables left in the config's `env` block.
    let keptEnv: [String]
}

/// Name components that mark a variable as a credential, matched against
/// the `_`-separated parts of the name: GITHUB_PERSONAL_ACCESS_TOKEN,
/// OPENAI_API_KEY, DB_PASSWORD, and so on.
private let secretNameParts: Set<String> = [
    "KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "PWD", "AUTH",
    "CREDENTIAL", "CREDENTIALS", "CRED", "CREDS", "PRIVATE", "SESSION", "COOKIE", "DSN", "PAT",
]

func looksLikeSecret(name: String, value: String) -> Bool {
    if name.uppercased().split(separator: "_").contains(where: { secretNameParts.contains(String($0)) }) { return true }
    // URLs with embedded credentials: postgres://user:pass@host/db
    if let scheme = value.range(of: "://"), let at = value.range(of: "@", range: scheme.upperBound..<value.endIndex) {
        return value[scheme.upperBound..<at.lowerBound].contains(":")
    }
    return false
}

func slug(_ s: String) -> String {
    let mapped = s.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? Character($0) : "-" }
    return String(mapped).split(separator: "-").joined(separator: "-")
}

/// Finds stdio MCP servers with literal credential values in their `env`,
/// in `mcpServers` and in Claude Code's `projects.<path>.mcpServers`.
///
/// Skips remote (http/sse) servers, servers already wrapped by mima, and
/// values that are already references such as `${GITHUB_TOKEN}`.
/// `takenGroups` keeps group names unique across files.
func planMCPImport(
    config: [String: Any], mimaPath: String, all: Bool, scrub: Bool, takenGroups: inout Set<String>
) -> [MCPServerPlan] {
    var serverMaps: [(prefix: [String], servers: [String: Any])] = []
    if let servers = config["mcpServers"] as? [String: Any] { serverMaps.append((["mcpServers"], servers)) }
    if let projects = config["projects"] as? [String: Any] {
        for (project, value) in projects.sorted(by: { $0.key < $1.key }) {
            if let servers = (value as? [String: Any])?["mcpServers"] as? [String: Any] {
                serverMaps.append((["projects", project, "mcpServers"], servers))
            }
        }
    }

    var plans: [MCPServerPlan] = []
    for (prefix, servers) in serverMaps {
        for (name, raw) in servers.sorted(by: { $0.key < $1.key }) {
            guard let server = raw as? [String: Any],
                  let command = server["command"] as? String, !command.isEmpty,
                  let env = server["env"] as? [String: Any]
            else { continue }
            if let type = server["type"] as? String, type != "stdio" { continue }
            if (command as NSString).lastPathComponent == "mima" { continue }

            var moving: [(String, String)] = []
            var kept: [String] = []
            for (key, value) in env.sorted(by: { $0.key < $1.key }) {
                guard let value = value as? String, !value.isEmpty, !value.hasPrefix("$"), isValidEnvVarName(key),
                      all || looksLikeSecret(name: key, value: value)
                else { kept.append(key); continue }
                moving.append((key, value))
            }
            guard !moving.isEmpty else { continue }

            var group = "mcp-\(slug(name))"
            var n = 2
            while takenGroups.contains(group) { group = "mcp-\(slug(name))-\(n)"; n += 1 }
            takenGroups.insert(group)

            let args = (server["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            // With --scrub, mima would strip the env vars the client still
            // passes from the config, so keep each one explicitly.
            let keepFlags = scrub ? kept.filter(isValidEnvVarName).flatMap { ["--keep", $0] } : []
            plans.append(MCPServerPlan(
                keyPath: prefix + [name],
                server: name,
                group: group,
                moves: moving.map { MCPMove(envVar: $0.0, secretName: "\(group)-\(slug($0.0))") },
                newCommand: mimaPath,
                newArgs: ["run"] + (scrub ? ["--scrub"] : []) + keepFlags + [group, "--", command] + args,
                keptEnv: kept
            ))
        }
    }
    return plans
}

/// Plaintext values for a plan, read from the config it was made from.
func mcpPlanValues(_ plan: MCPServerPlan, config: [String: Any]) -> [String: String] {
    guard let env = value(at: plan.keyPath, in: config).flatMap({ ($0 as? [String: Any])?["env"] as? [String: Any] })
    else { return [:] }
    var out: [String: String] = [:]
    for move in plan.moves { out[move.envVar] = env[move.envVar] as? String }
    return out
}

/// Rewrites each planned server: command → mima, args → `run <group> --
/// <original>`, and the moved variables removed from `env`. Other keys are
/// left alone.
func applyMCPPlans(_ plans: [MCPServerPlan], to config: [String: Any]) -> [String: Any] {
    var config = config
    for plan in plans {
        guard var server = value(at: plan.keyPath, in: config) as? [String: Any] else { continue }
        server["command"] = plan.newCommand
        server["args"] = plan.newArgs
        var env = server["env"] as? [String: Any] ?? [:]
        for move in plan.moves { env.removeValue(forKey: move.envVar) }
        if env.isEmpty { server.removeValue(forKey: "env") } else { server["env"] = env }
        config = setting(server, at: plan.keyPath, in: config)
    }
    return config
}

private func value(at path: [String], in object: [String: Any]) -> Any? {
    var current: Any? = object
    for key in path { current = (current as? [String: Any])?[key] }
    return current
}

private func setting(_ newValue: Any, at path: [String], in object: [String: Any]) -> [String: Any] {
    guard let first = path.first else { return object }
    var copy = object
    if path.count == 1 {
        copy[first] = newValue
    } else {
        copy[first] = setting(newValue, at: Array(path.dropFirst()), in: object[first] as? [String: Any] ?? [:])
    }
    return copy
}
