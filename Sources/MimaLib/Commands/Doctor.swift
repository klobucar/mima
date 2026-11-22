import ArgumentParser
import Foundation
import Security

/// Reports whether this install actually enforces Touch ID, instead of
/// leaving the user to infer it from build flags.
struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check signing, Touch ID protection, and group mappings",
        discussion: """
        Verifies the binary's signature and keychain entitlement. Then it \
        stores and deletes a throwaway item behind a Touch ID ACL, which \
        involves no read and no prompt. Finally it lists secrets stored \
        without protection and group mappings that point at missing secrets.
        """
    )

    func run() throws {
        var problems = 0
        func ok(_ s: String) { print("✅ \(s)") }
        func bad(_ s: String) { print("❌ \(s)"); problems += 1 }
        func warn(_ s: String) { print("⚠️  \(s)") }

        // 1. Signature
        let signing = Self.signingInfo()
        if let team = signing.team {
            ok("Signed by team \(team) as \(signing.identifier ?? "?")")
        } else {
            bad("Not signed with a team identity (\(signing.identifier.map { "identifier \($0), " } ?? "")ad-hoc or unsigned)")
        }

        // 2. Entitlement and protected storage
        let keychain = NativeKeychain()
        if keychain.isEntitled {
            ok("keychain-access-groups entitlement present")
            if let status = keychain.probeProtectedStorage() {
                bad("Could not store a Touch ID-protected item: \(KeychainError.unknown(status))")
            } else {
                ok("Touch ID-protected storage works (stored and deleted a throwaway item)")
            }
        } else {
            bad("No keychain-access-groups entitlement: secrets are stored WITHOUT Touch ID protection")
            print("   Rebuild with: make install SIGNING_IDENTITY=\"Apple Development: …\" (see README → Install)")
        }

        // 3. Secrets
        let protected = keychain.isEntitled ? ((try? keychain.list()) ?? []) : []
        let unprotected = (try? keychain.listUnprotected()) ?? []
        print("   Secrets: \(protected.count) protected, \(unprotected.count) unprotected")
        if !unprotected.isEmpty {
            let names = unprotected.map { $0.debugDescription }.joined(separator: ", ")
            if keychain.isEntitled {
                bad("Unprotected secrets that this build will refuse to read: \(names)")
                print("   Migrate each with: mima secret remove <name>, then mima secret add <name>")
            } else {
                warn("Readable without a prompt by any process running as you: \(names)")
            }
        }

        // 4. Group mappings that point nowhere
        let known = Set(protected + (keychain.isEntitled ? [] : unprotected))
        let config = try ConfigManager.shared.load()
        for (group, mappings) in config.groups.sorted(by: { $0.key < $1.key }) {
            for (envVar, mapping) in mappings.sorted(by: { $0.key < $1.key }) where !known.contains(mapping.secret) {
                bad("Group \(group.debugDescription): \(envVar.debugDescription) -> missing secret \(mapping.secret.debugDescription)")
            }
        }

        if problems > 0 { throw ExitCode.failure }
    }

    /// Team ID and identifier from this process's own code signature.
    static func signingInfo() -> (team: String?, identifier: String?) {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return (nil, nil) }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String,
                dict[kSecCodeInfoIdentifier as String] as? String)
    }
}
