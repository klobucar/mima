import ArgumentParser
import Foundation
import Darwin

struct Secret: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage secrets in the Secure Enclave",
        subcommands: [Add.self, Remove.self, List.self, Get.self]
    )
    
    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a new secret")
        
        @Argument(help: "The name of the secret")
        var name: String
        
        @Argument(help: "The value of the secret (optional)")
        var value: String?
        
        func run() throws {
            let secretValue: String
            if let v = value {
                secretValue = v
            } else {
                // Secure input
                guard let cString = getpass("Enter value for '\(name)': ") else {
                    print("Error: Failed to read password")
                    return
                }
                secretValue = String(cString: cString)
            }
            
            guard let data = secretValue.data(using: .utf8) else {
                print("Error: Invalid formatting")
                return
            }
            
            do {
                try KeychainManager.shared.add(key: name, value: data)
                print("✅ Secret '\(name)' added to Keychain with Strict Biometric ACL.")
            } catch {
                print("Error adding secret: \(error)")
            }
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
