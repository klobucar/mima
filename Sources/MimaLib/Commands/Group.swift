import ArgumentParser
import Foundation

struct Group: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage Identity Groups and their environment mappings",
        subcommands: [Link.self, List.self]
    )
    
    struct Link: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Link an Env Var to a Secret for a Group")
        
        @Argument(help: "The group name (e.g. 'backend')")
        var group: String
        
        @Argument(help: "The environment variable name (e.g. 'STRIPE_KEY')")
        var envVar: String
        
        @Argument(help: "The name of the secret in Keychain")
        var secretName: String
        
        func run() throws {
            // Validation: Check if secret exists
            do {
                let existing = try KeychainManager.shared.list()
                if !existing.contains(secretName) {
                    print("⚠️ Warning: Secret '\(secretName)' not found in Keychain. You should add it with 'mima secret add \(secretName)'.")
                }
            } catch {
                print("⚠️ Warning: Could not verify secret existence: \(error)")
            }
            
            try ConfigManager.shared.link(group: group, envVar: envVar, secretName: secretName)
            print("🔗 Linked '\(envVar)' -> '\(secretName)' in group '\(group)'.")
        }
    }
    
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all groups and mappings")
        
        func run() throws {
            let config = try ConfigManager.shared.load()
            if config.groups.isEmpty {
                print("No groups configured.")
                return
            }
            
            for (group, vars) in config.groups {
                print("📦 \(group)")
                for (env, secret) in vars {
                    print("  ├─ \(env) -> \(secret)")
                }
            }
        }
    }
}
