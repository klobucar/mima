import ArgumentParser
import Foundation
import LocalAuthentication

struct Env: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print secrets to stdout (Debug)",
        discussion: "WARNING: This prints secrets to your shell history/stdout."
    )
    
    @Argument(help: "The group to load secrets for")
    var group: String

    @Flag(help: "Print even when started by an AI agent or without a terminal. The Touch ID prompt still names the caller.")
    var force = false

    func run() throws {
        // Warning to stderr
        fputs("⚠️  Warning: Secrets loaded into shell history/logs.\n", stderr)
        
        let mappings = try ConfigManager.shared.getSecrets(for: group)
        if mappings.isEmpty {
            fputs("No secrets found for group '\(group)'.\n", stderr)
            return
        }

        // This output gets eval'd, and names are emitted unquoted. Refuse
        // the whole group before unlocking anything if any name is unsafe.
        let invalid = invalidEnvVarNames(in: mappings)
        guard invalid.isEmpty else {
            for name in invalid {
                fputs("Error: group '\(group)': \(InvalidEnvVarName(name: name))\n", stderr)
            }
            throw ExitCode.failure
        }

        let chain = currentCallerChain()
        let agent = detectAgent(environment: ProcessInfo.processInfo.environment, chain: chain)
        if let refusal = secretOutputRefusal(
            force: force, agent: agent, chain: chain, stdinIsTTY: isTTY(STDIN_FILENO), stderrIsTTY: isTTY(STDERR_FILENO)
        ) {
            fputs(refusal + "\n", stderr)
            throw ExitCode.failure
        }

        // Context for batch unlock
        let context = LAContext()
        context.localizedReason = unlockReason(
            action: "print \(mappings.count) secret\(mappings.count == 1 ? "" : "s") from group '\(sanitizeForPrompt(group, limit: 32))' as shell exports",
            secrets: Array(mappings.values), chain: chain, agent: agent
        )

        for (envVar, secretName) in mappings {
            do {
                let secretData = try KeychainManager.shared.get(key: secretName, context: context)
                if let secretValue = String(data: secretData, encoding: .utf8) {
                    print(try exportLine(name: envVar, value: secretValue))
                }
            } catch {
                fputs("Failed to retrieve '\(secretName)': \(error)\n", stderr)
            }
        }
    }
}
