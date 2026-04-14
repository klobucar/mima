import ArgumentParser
import Foundation
import LocalAuthentication

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command with secrets injected",
        discussion: "Batch unlocks secrets using Touch ID and injects them into the environment."
    )
    
    @Argument(help: "The group to load secrets for")
    var group: String
    
    @Argument(parsing: .captureForPassthrough, help: "The command to run (use -- to separate)")
    var command: [String]
    
    func run() throws {
        guard !command.isEmpty else {
            print("Error: No command provided.")
            throw ExitCode.validationFailure
        }
        
        // 1. Load Config
        let mappings = try ConfigManager.shared.getSecrets(for: group)
        if mappings.isEmpty {
            print("⚠️ No secrets found for group '\(group)'. Running command explicitly without added secrets.")
        }
        
        // 2. Batch Unlock
        var secretsEnv: [String: String] = [:]
        
        if !mappings.isEmpty {
            // One Tap: Reuse context
            let context = LAContext()
            context.localizedReason = "Access secrets for '\(group)'"
            
            // Pre-flight check (optional, but good for UX to fail fast if no biometrics)
             var authError: NSError?
             if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) {
                 // Good to go
             } else {
                 print("⛔️ Identity fracture detected: Biometrics not available.")
                 throw ExitCode.failure
             }

            print("🔓 Authenticating for '\(group)'...")
            
            for (envVar, secretName) in mappings {
                do {
                    let secretData = try KeychainManager.shared.get(key: secretName, context: context)
                    if let secretValue = String(data: secretData, encoding: .utf8) {
                        secretsEnv[envVar] = secretValue
                    }
                } catch {
                     print("⛔️ Identity fracture detected: Failed to retrieve '\(secretName)': \(error)")
                     throw ExitCode.failure
                }
            }
        }
        
        // 3. Prepare Environment
        var env = ProcessInfo.processInfo.environment
        env.merge(secretsEnv) { (_, new) in new }
        
        // 4. Exec
        let executable = command[0]
        let args = command
        
        // Convert to C-compatible strings
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { $0.withCString(strdup) } + [nil]
        
        // Convert env to C-compatible array
        // Format: key=value
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { "\($0.key)=\($0.value)".withCString(strdup) } + [nil]
        
        // Use executvp (search path) or execv (direct path)
        // Usually we want shell path resolution, so execvp is better, but Swift doesn't expose it directly easily without bridging header sometimes?
        // Actually execvp is in Foundation (Darwin)
        
        // We need to find the full path if it's not absolute? execvp does that.
        // But `execvp` replaces process.
        
        argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envpBuffer in
                // execvP (file, argv) uses PATH. But we also want to set ENVP.
                // execve (file, argv, envp) does NOT use PATH.
                // If we want PATH resolution + custom ENV, we might need to resolve path manually or use posix_spawnp?
                // Or just update `environ` global variable and use execvp.
                
                // Simpler approach: update setenv for current process, then execvp
                for (k, v) in secretsEnv {
                    setenv(k, v, 1) // 1 = overwrite
                }
                
                // Now simple execvp
                execvp(executable, argvBuffer.baseAddress)
            }
        }
        
        // If we return, it failed
        let error = String(cString: strerror(errno))
        print("Error executing command: \(error)")
        throw ExitCode.failure
    }
}
