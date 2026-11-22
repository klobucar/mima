import ArgumentParser
import Foundation

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Move plaintext credentials out of MCP server configs",
        subcommands: [Import.self]
    )

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move MCP servers' plaintext env credentials into the Keychain",
            discussion: """
            Scans ~/.claude.json (user and per-project servers), ./.mcp.json, \
            Claude Desktop, and Cursor configs. For each stdio server whose \
            `env` holds a literal credential, it stores the value as a secret, \
            links it into a group mcp-<server>, and rewrites the server to \
            launch through `mima run <group> -- <original command>`.

            Dry run by default: prints the plan with names only, never values. \
            --apply makes the changes and first writes a 0600 backup of each \
            config. Quit the owning app first, or it may write the old \
            plaintext back.
            """
        )

        @Option(name: .customLong("config"), help: ArgumentHelp("Only process this config file. Repeatable.", valueName: "path"))
        var configs: [String] = []

        @Flag(help: "Make the changes. Without this, only print the plan.")
        var apply = false

        @Flag(help: "Move every literal env value, not just ones that look like credentials.")
        var all = false

        @Flag(help: "Launch servers with `mima run --scrub`, keeping the env vars still listed in the config.")
        var scrub = false

        @Flag(help: "If a secret with the same name exists, replace its value instead of skipping the server.")
        var overwrite = false

        @Flag(help: "With --apply, rewrite configs even if the app that owns them is running.")
        var force = false

        func run() throws {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let cwd = FileManager.default.currentDirectoryPath
            let locations = configs.isEmpty
                ? defaultMCPConfigLocations(home: home, cwd: cwd).filter { FileManager.default.fileExists(atPath: $0.path) }
                : configs.map { MCPConfigLocation(path: ($0 as NSString).expandingTildeInPath, label: "--config", ownerProcesses: []) }
            guard !locations.isEmpty else {
                print("No MCP config files found.")
                return
            }

            let mimaPath = currentMimaPath()
            var takenGroups = Set(try ConfigManager.shared.load().groups.keys)
            var failures = 0
            var appliedAny = false

            for location in locations {
                let original: Data
                let config: [String: Any]
                do {
                    original = try Data(contentsOf: URL(fileURLWithPath: location.path))
                    guard let parsed = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                        throw CocoaError(.propertyListReadCorrupt)
                    }
                    config = parsed
                } catch {
                    fputs("⚠️  \(location.path): not readable JSON; skipped (\(error.localizedDescription))\n", stderr)
                    failures += 1
                    continue
                }

                let plans = planMCPImport(config: config, mimaPath: mimaPath, all: all, scrub: scrub, takenGroups: &takenGroups)
                print("📄 \(location.path) (\(location.label))")
                if plans.isEmpty {
                    print("   nothing to move")
                    continue
                }
                for plan in plans {
                    let scope = plan.keyPath.count > 2 ? " [project \(plan.keyPath[1])]" : ""
                    print("   🔌 \(plan.server)\(scope) → group \(plan.group)")
                    for move in plan.moves { print("      \(move.envVar) → Keychain secret \(move.secretName)") }
                    if !plan.keptEnv.isEmpty { print("      left in config: \(plan.keptEnv.joined(separator: ", "))") }
                    print("      command: \(([plan.newCommand] + plan.newArgs).map(shellDisplay).joined(separator: " "))")
                }
                guard apply else { continue }

                if !force, let running = location.ownerProcesses.first(where: isProcessRunning) {
                    fputs("⛔️ \(running) is running and keeps \(location.path) in memory; it could write the plaintext back. Quit it and re-run, or pass --force.\n", stderr)
                    failures += 1
                    continue
                }

                // Store secrets first. A server is rewritten only if all of
                // its secrets were stored and linked.
                var done: [MCPServerPlan] = []
                for plan in plans {
                    if storeAndLink(plan, values: mcpPlanValues(plan, config: config)) { done.append(plan) } else { failures += 1 }
                }
                guard !done.isEmpty else { continue }

                do {
                    let backup = try writeBackup(of: location.path, data: original)
                    // Abort if the file changed since we read it: someone else
                    // is writing to it, and our rewrite would clobber that.
                    guard (try? Data(contentsOf: URL(fileURLWithPath: location.path))) == original else {
                        fputs("⛔️ \(location.path) changed while mima was working; not rewritten. Secrets were stored; re-run to rewrite the config.\n", stderr)
                        failures += 1
                        continue
                    }
                    try writeJSONPreservingMode(applyMCPPlans(done, to: config), to: location.path)
                    appliedAny = true
                    print("   ✅ rewrote \(done.count) server(s); backup at \(backup)")
                } catch {
                    fputs("❌ \(location.path): \(error.localizedDescription)\n", stderr)
                    failures += 1
                }
            }

            if !apply {
                print("\nDry run. Re-run with --apply to make these changes.")
            } else if appliedAny {
                fputs(
                    "⚠️  These values sat in plaintext in the configs above, and the backups still hold them (mode 0600).\n"
                        + "   Restart the apps, confirm the servers work, then delete the backups. If a config was ever\n"
                        + "   committed, shared, or synced (.mcp.json often is), rotate the values.\n",
                    stderr
                )
            }
            if failures > 0 { throw ExitCode.failure }
        }

        private func storeAndLink(_ plan: MCPServerPlan, values: [String: String]) -> Bool {
            for move in plan.moves {
                guard let value = values[move.envVar] else { return false }
                let data = Data(value.utf8)
                do {
                    try validateSecretValue(data)
                    do {
                        try KeychainManager.shared.add(key: move.secretName, value: data)
                    } catch KeychainError.duplicateEntry where overwrite {
                        try KeychainManager.shared.update(key: move.secretName, value: data)
                    }
                    try ConfigManager.shared.link(group: plan.group, envVar: move.envVar, secretName: move.secretName)
                } catch {
                    var hint = ""
                    if case KeychainError.duplicateEntry = error { hint = " (use --overwrite to replace)" }
                    fputs("❌ \(plan.server): \(move.envVar): \(error)\(hint)\n", stderr)
                    return false
                }
            }
            return true
        }
    }
}

/// Path written into MCP configs. A symlink like /usr/local/bin/mima is
/// kept as is, since it survives reinstalls. MCP clients often launch
/// servers with a minimal PATH, so the path must be absolute.
func currentMimaPath() -> String {
    let argv0 = CommandLine.arguments[0]
    if argv0.contains("/") {
        return URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
    }
    return resolveExecutable(argv0, pathEnv: ProcessInfo.processInfo.environment["PATH"] ?? "") ?? argv0
}

private func shellDisplay(_ s: String) -> String {
    s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@".contains($0) }) ? s : shellSingleQuote(s)
}

private func isProcessRunning(_ name: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "-u", "\(getuid())", name]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

private func writeBackup(of path: String, data: Data) throws -> String {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
    let backup = "\(path).mima-backup-\(stamp)"
    guard FileManager.default.createFile(atPath: backup, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: backup])
    }
    return backup
}

private func writeJSONPreservingMode(_ object: [String: Any], to path: String) throws {
    let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
    data.append(UInt8(ascii: "\n"))
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}
