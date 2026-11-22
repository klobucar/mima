import ArgumentParser
import Foundation
import LocalAuthentication
import Darwin

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command with secrets injected",
        discussion: """
        Batch unlocks secrets using Touch ID and injects them into the environment.

        By default the command also inherits your full environment. With --scrub \
        it gets only the group's secrets plus PATH, HOME, USER, LOGNAME, SHELL, \
        TERM, TMPDIR, LANG, TZ, and LC_*. Use --scrub for coding agents.

        Options go before the group name: mima run --scrub <group> -- <command>
        """
    )

    @Flag(help: "Pass only the group's secrets and a minimal safelist to the command, not your full environment.")
    var scrub = false

    @Option(
        name: .customLong("keep"),
        help: ArgumentHelp("With --scrub, also pass this variable from your environment. Repeatable.", valueName: "VAR")
    )
    var keep: [String] = []

    @Argument(help: "The group to load secrets for")
    var group: String

    @Argument(parsing: .captureForPassthrough, help: "The command to run (use -- to separate)")
    var command: [String]

    /// The child's argv. `.captureForPassthrough` keeps the `--`
    /// terminator as the first captured element, so the documented
    /// `mima run <group> -- cmd` form would otherwise try to exec `--`.
    /// Only a leading `--` is stripped, so `mima run g cmd -- x` still
    /// passes `--` through to `cmd`.
    var childArgv: [String] {
        command.first == "--" ? Array(command.dropFirst()) : command
    }

    func validate() throws {
        if !keep.isEmpty && !scrub {
            throw ValidationError("--keep only applies with --scrub (without it the command already inherits everything).")
        }
        for name in keep where !isValidEnvVarName(name) {
            throw ValidationError("--keep: \(InvalidEnvVarName(name: name))")
        }
        // Everything after the group is captured for the child, so
        // `mima run g --scrub -- cmd` would try to exec "--scrub" and
        // silently skip the scrub. Catch that with a clear message.
        if let first = childArgv.first, first == "--scrub" || first == "--keep" || first.hasPrefix("--keep=") {
            throw ValidationError("Put \(first) before the group name: mima run \(first) <group> -- <command>")
        }
    }

    func run() throws {
        let command = childArgv
        guard !command.isEmpty else {
            fputs("Error: No command provided.\n", stderr)
            throw ExitCode.validationFailure
        }

        // 1. Load Config
        let mappings = try ConfigManager.shared.getSecrets(for: group)
        if mappings.isEmpty {
            print("⚠️ No secrets found for group '\(group)'. Running command explicitly without added secrets.")
        }

        // Each name becomes the part of a `NAME=value` envp entry before
        // the first `=`. A name containing `=`, or an empty name, would
        // shadow or corrupt other variables. Refuse before unlocking.
        let invalid = invalidEnvVarNames(in: mappings)
        guard invalid.isEmpty else {
            for name in invalid {
                fputs("⛔️ Error: group '\(group)': \(InvalidEnvVarName(name: name))\n", stderr)
            }
            throw ExitCode.failure
        }

        // 2. Batch Unlock — one LAContext, one Touch ID prompt for N secrets.
        var secretsEnv: [String: String] = [:]

        if !mappings.isEmpty {
            let context = LAContext()
            context.localizedReason = "Access secrets for '\(group)'"

            var authError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
                fputs("⛔️ Identity fracture detected: Biometrics not available.\n", stderr)
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
                    fputs("⛔️ Identity fracture detected: Failed to retrieve '\(secretName)': \(error)\n", stderr)
                    throw ExitCode.failure
                }
            }
        }

        // 3. Build the child env: our env (or just the safelist, with
        //    --scrub) plus the secrets. We deliberately do NOT touch the
        //    parent process env — no setenv, no getenv-visible window where
        //    a crash dump or child thread could observe a secret that
        //    isn't ours to expose.
        let childEnv = buildChildEnvironment(
            parent: ProcessInfo.processInfo.environment,
            secrets: secretsEnv,
            scrub: scrub,
            keep: keep
        )

        // 4. execve doesn't do PATH lookup; reproduce execvp's lookup
        //    using the child's PATH so behaviour matches the shell.
        let executable = command[0]
        let resolvedPath: String
        if executable.contains("/") {
            resolvedPath = executable
        } else {
            guard let found = resolveExecutable(executable, pathEnv: childEnv["PATH"] ?? "") else {
                fputs("Error: command not found: \(executable)\n", stderr)
                throw ExitCode.failure
            }
            resolvedPath = found
        }

        // 5. Hand off to execve. On success this call replaces the
        //    current process image, so argv/envp strdups never get
        //    freed — that's fine, the whole address space is gone.
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            childEnv.map { strdup("\($0.key)=\($0.value)") } + [nil]

        argv.withUnsafeBufferPointer { argvBuf in
            envp.withUnsafeBufferPointer { envpBuf in
                _ = execve(resolvedPath, argvBuf.baseAddress, envpBuf.baseAddress)
            }
        }

        // If we're still here, execve failed. Free what we leaked so
        // the failure path is clean, then report and exit.
        for ptr in argv { free(ptr) }
        for ptr in envp { free(ptr) }
        let err = String(cString: strerror(errno))
        fputs("Error executing '\(resolvedPath)': \(err)\n", stderr)
        throw ExitCode.failure
    }
}
