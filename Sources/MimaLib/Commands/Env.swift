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

        // Context for batch unlock
        let context = LAContext()
        context.localizedReason = "Access secrets for '\(group)'"
        
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
