import ArgumentParser
import Foundation
import Darwin

struct Secret: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage secrets in the Secure Enclave",
        subcommands: [Add.self, Update.self, Remove.self, List.self, Get.self]
    )
    
    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a new secret")
        
        @Argument(help: "The name of the secret")
        var name: String
        
        @Argument(help: "The value (optional; avoid it, since it lands in shell history). Without it, mima prompts without echo.")
        var value: String?

        @Flag(help: "Read the value from stdin, e.g. `pbpaste | mima secret add x --stdin`. One trailing newline is stripped.")
        var stdin = false

        func validate() throws {
            if stdin && value != nil { throw ValidationError("Pass the value as an argument or with --stdin, not both.") }
        }

        func run() throws {
            let data: Data
            do {
                data = try readSecretValue(prompt: "Enter value for '\(name)': ", inline: value, fromStdin: stdin)
            } catch {
                fputs("Error: \(error)\n", stderr)
                throw ExitCode.failure
            }

            let protection: KeychainProtection
            do {
                protection = try KeychainManager.shared.add(key: name, value: data)
            } catch {
                fputs("Error adding secret '\(name)': \(error)\n", stderr)
                throw ExitCode.failure
            }
            switch protection {
            case .userPresence:
                print("✅ Secret '\(name)' added. Reading it requires Touch ID or your login password.")
            case .none:
                print("✅ Secret '\(name)' added.")
                fputs(
                    "⚠️  Stored WITHOUT Touch ID protection: this mima binary isn't signed with a team identity and "
                        + "provisioning profile, so any process running as you can read the value without a prompt. "
                        + "See README → Install, and run 'mima doctor'.\n",
                    stderr
                )
            }
        }
    }
    
    struct Update: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace an existing secret's value",
            discussion: "Keeps the secret's name, group mappings, and Touch ID protection. Use after rotating a key."
        )

        @Argument(help: "The name of the secret")
        var name: String

        @Argument(help: "The new value (optional; avoid it, since it lands in shell history). Without it, mima prompts without echo.")
        var value: String?

        @Flag(help: "Read the new value from stdin. One trailing newline is stripped.")
        var stdin = false

        func validate() throws {
            if stdin && value != nil { throw ValidationError("Pass the value as an argument or with --stdin, not both.") }
        }

        func run() throws {
            do {
                let data = try readSecretValue(prompt: "New value for '\(name)': ", inline: value, fromStdin: stdin)
                try KeychainManager.shared.update(key: name, value: data)
            } catch KeychainError.itemNotFound {
                fputs("Error: no secret named '\(name)'. Create it with 'mima secret add \(name)'.\n", stderr)
                throw ExitCode.failure
            } catch {
                fputs("Error updating secret '\(name)': \(error)\n", stderr)
                throw ExitCode.failure
            }
            print("🔁 Secret '\(name)' updated.")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a secret", aliases: ["rm"])
        
        @Argument(help: "The name of the secret to remove")
        var name: String
        
        func run() throws {
            do {
                try KeychainManager.shared.delete(key: name)
                print("🗑️ Secret '\(name)' removed.")
            } catch {
                print("Error deleting secret: \(error)")
            }
        }
    }
    
    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Retrieve a single secret")
        
        @Argument(help: "The name of the secret to retrieve")
        var name: String
        
        @Flag(help: "Format as 'export NAME=VALUE' for eval")
        var export: Bool = false

        /// Infer the env var from the secret name: test-key -> TEST_KEY.
        static func exportName(for name: String) -> String {
            name.uppercased().replacingOccurrences(of: "-", with: "_")
        }

        // Runs before any Keychain access, so a name that can't be
        // exported never triggers a Touch ID prompt.
        func validate() throws {
            if export && !isValidEnvVarName(Self.exportName(for: name)) {
                throw ValidationError(
                    "--export: \(InvalidEnvVarName(name: Self.exportName(for: name))). Link the secret into a group and use 'mima env' to pick a name."
                )
            }
        }

        func run() throws {
            // Warning to stderr
            fputs("⚠️  Warning: Secret loaded into shell history/logs.\n", stderr)
            
            do {
                let data = try KeychainManager.shared.get(key: name, context: nil)
                guard let value = String(data: data, encoding: .utf8) else {
                    print("Error: Invalid UTF-8 data")
                    return
                }
                
                if export {
                    print(try exportLine(name: Self.exportName(for: name), value: value))
                } else {
                    print(value)
                }
            } catch {
                fputs("Error retrieving secret: \(error)\n", stderr)
                throw ExitCode.failure
            }
        }
    }
    
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all secret names")
        
        func run() throws {
            do {
                let items = try KeychainManager.shared.list()
                if items.isEmpty {
                    print("No secrets found.")
                } else {
                    for item in items {
                        print("• \(item)")
                    }
                }
            } catch {
                print("Error listing secrets: \(error)")
            }
        }
    }
}
