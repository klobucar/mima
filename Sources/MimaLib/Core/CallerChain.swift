import Foundation
import Darwin

/// One ancestor of the current process.
struct CallerProcess: Equatable {
    let pid: pid_t
    /// Executable basename, e.g. "zsh". For script interpreters (node,
    /// python, ...) this is "interpreter(script)", e.g. "node(claude)", so
    /// npm-installed agents are still recognizable.
    let name: String
}

/// AI coding agents recognized by executable or script basename.
let knownAgentExecutables: [String: String] = [
    "claude": "Claude Code",
    "codex": "Codex",
    "aider": "aider",
    "cursor-agent": "Cursor",
    "gemini": "Gemini CLI",
    "opencode": "opencode",
    "goose": "Goose",
]

private let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl"]

/// The parent-process chain, outermost first, ending at our direct
/// parent. Stops below launchd, after `maxDepth` hops, or when a lookup
/// fails.
func currentCallerChain(maxDepth: Int = 12) -> [CallerProcess] {
    var chain: [CallerProcess] = []
    var pid = getppid()
    while pid > 1 && chain.count < maxDepth {
        guard let info = kinfoProc(pid) else { break }
        chain.append(CallerProcess(pid: pid, name: displayName(pid: pid, info: info)))
        pid = info.kp_eproc.e_ppid
    }
    return chain.reversed()
}

private func kinfoProc(_ pid: pid_t) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
}

private func displayName(pid: pid_t, info: kinfo_proc) -> String {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    var name: String
    if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
        name = (String(cString: path) as NSString).lastPathComponent
    } else {
        var comm = info.kp_proc.p_comm
        name = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    var args: [String]?
    // Versioned installs exec a file named after the version: Claude Code
    // runs ~/.local/share/claude/versions/2.1.330, which shows up as
    // "2.1.330". In that case argv[0] ("claude") is the meaningful name.
    if name.isEmpty || name.first?.isNumber == true {
        args = processArguments(pid)
        if let argv0 = args?.first, !argv0.isEmpty {
            name = (argv0 as NSString).lastPathComponent
            if name.hasPrefix("-") { name.removeFirst() }  // login shells: "-zsh"
        }
    }
    if interpreters.contains(name),
       let script = (args ?? processArguments(pid)).dropFirst().first(where: { !$0.hasPrefix("-") }) {
        name += "(\(scriptName(script)))"
    }
    return name
}

/// A readable name for an interpreter's script argument. For
/// "…/node_modules/@anthropic-ai/claude-code/cli.js", that is "claude".
func scriptName(_ path: String) -> String {
    let parts = path.split(separator: "/").map(String.init)
    let base = parts.last.map { ($0 as NSString).deletingPathExtension } ?? path
    if ["cli", "index", "main"].contains(base), parts.count >= 2 {
        let pkg = parts[parts.count - 2]
        return pkg == "claude-code" ? "claude" : pkg
    }
    return base
}

/// argv of another process you own, via KERN_PROCARGS2.
private func processArguments(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var argmax: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return [] }
    var buf = [UInt8](repeating: 0, count: Int(argmax))
    size = buf.count
    mib = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }  // exec path
    while i < size && buf[i] == 0 { i += 1 }  // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}

// MARK: - Agent detection

struct AgentDetection: Equatable {
    let agent: String
    let evidence: String
}

/// Decides whether mima is running under an AI coding agent.
///
/// This is a speed bump, not a boundary. The agent runs as you, so it can
/// unset variables or double-fork out of the process tree. The point is
/// to stop naive or prompt-injected requests, and to label the Touch ID
/// prompt so a human can tell when an agent is asking.
///
/// `CLAUDECODE=1` alone is not enough: Claude Code's IDE extensions also
/// set it in terminals a person types into. `CLAUDE_CODE_CHILD_SESSION=1`
/// is set only in subprocesses Claude Code itself spawns.
func detectAgent(environment: [String: String], chain: [CallerProcess]) -> AgentDetection? {
    if environment["CLAUDE_CODE_CHILD_SESSION"] == "1" {
        return AgentDetection(agent: "Claude Code", evidence: "CLAUDE_CODE_CHILD_SESSION=1")
    }
    for process in chain.reversed() {
        let names = [process.name] + (process.name.split(separator: "(").count > 1
            ? [String(process.name.split(separator: "(")[1].dropLast())] : [])
        for name in names {
            if let agent = knownAgentExecutables[name.lowercased()] {
                return AgentDetection(agent: agent, evidence: "process \(process.name) (pid \(process.pid))")
            }
        }
    }
    return nil
}

// MARK: - Guarding commands that print secrets

/// Returns a refusal message if `mima env` or `mima secret get` should
/// not print secret values, or nil to proceed.
///
/// Printed values end up wherever stdout goes, and under an agent that is
/// the agent's transcript, which is sent to a model provider. The agent
/// refusal doesn't mention `--force`, so an agent reading the error isn't
/// handed the bypass. `--help` documents it for people.
func secretOutputRefusal(
    force: Bool, agent: AgentDetection?, chain: [CallerProcess], stdinIsTTY: Bool, stderrIsTTY: Bool
) -> String? {
    if force { return nil }
    if let agent {
        return "⛔️ Refusing to print secret values: mima was started by an AI agent (\(agent.agent); "
            + "\(describeChain(chain))). Anything printed here lands in the agent's transcript. "
            + "To give a command secrets without printing them, use: mima run --scrub <group> -- <command>"
    }
    if !stdinIsTTY && !stderrIsTTY {
        return "⛔️ Refusing to print secret values without a terminal (neither stdin nor stderr is a TTY). "
            + "Run it from a terminal, or pass --force in a script you trust."
    }
    return nil
}

// MARK: - Touch ID prompt text

/// Text for `LAContext.localizedReason`. macOS shows it as
/// "mima is trying to <reason>." It names what is being released, to what,
/// and who asked, so a remapped group or an agent's request is visible at
/// the moment of approval.
func unlockReason(action: String, secrets: [String], chain: [CallerProcess], agent: AgentDetection?) -> String {
    let names = secrets.sorted().map { sanitizeForPrompt($0, limit: 32) }
    let listed = names.count > 4 ? names.prefix(4).joined(separator: ", ") + ", +\(names.count - 4) more" : names.joined(separator: ", ")
    var reason = "\(action) (\(listed))"
    if let agent {
        reason += ". ⚠️ Requested by an AI agent (\(sanitizeForPrompt(agent.agent, limit: 24))) via \(describeChain(chain))"
    } else if !chain.isEmpty {
        reason += ". Requested via \(describeChain(chain))"
    }
    return String(reason.prefix(400))
}

/// "Terminal → zsh → claude → mima", keeping the `last` nearest ancestors.
func describeChain(_ chain: [CallerProcess], last: Int = 4) -> String {
    var parts = chain.suffix(last).map { sanitizeForPrompt($0.name, limit: 24) }
    if chain.count > last { parts.insert("…", at: 0) }
    return (parts + ["mima"]).joined(separator: " → ")
}

/// Strips control and bidi-override characters, and caps the length.
/// Group, secret, and process names are attacker-influenced, and must
/// not be able to fake text inside a system authentication dialog.
func sanitizeForPrompt(_ s: String, limit: Int) -> String {
    let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
        if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format { return false }
        if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) { return false }
        return true
    }))
    return cleaned.count > limit ? String(cleaned.prefix(limit - 1)) + "…" : cleaned
}

func isTTY(_ fd: Int32) -> Bool { isatty(fd) != 0 }
