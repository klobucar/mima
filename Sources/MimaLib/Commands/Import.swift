import ArgumentParser
import Foundation

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move a .env file's values into the Keychain and a group",
        discussion: """
        Each KEY=value becomes a Keychain secret named <prefix>-<key> \
        (lowercased, with _ as -) and a mapping KEY -> that secret in \
        <group>. The prefix defaults to the group name. Values are never \
        printed. The file is not modified or deleted.
        """
    )

    @Argument(help: "Path to the .env file")
    var file: String

    @Option(help: "Group to link the variables into")
    var group: String

    @Option(help: "Secret name prefix (default: the group name)")
    var prefix: String?

    @Flag(help: "Replace the value of secrets that already exist instead of skipping them")
    var overwrite = false

    func run() throws {
        let text: String
        do {
            text = try String(contentsOfFile: file, encoding: .utf8)
        } catch {
            fputs("Error: can't read \(file): \(error.localizedDescription)\n", stderr)
            throw ExitCode.failure
        }
        let pairs: [(key: String, value: String)]
        do {
            pairs = try parseDotEnv(text)
        } catch {
            fputs("Error: \(file): \(error)\n", stderr)
            throw ExitCode.failure
        }
        guard !pairs.isEmpty else {
            fputs("No variables found in \(file).\n", stderr)
            return
        }

        let results = try importDotEnv(
            pairs, group: group, prefix: prefix ?? group, overwrite: overwrite,
            keychain: KeychainManager.shared, config: ConfigManager.shared
        )

        var unprotected = false
        for r in results {
            switch r.status {
            case .added(let protection):
                unprotected = unprotected || protection == .none
                print("✅ \(r.envVar) -> \(r.secretName)")
            case .updated:
                print("🔁 \(r.envVar) -> \(r.secretName) (value replaced)")
            case .skippedExisting:
                fputs("⏭️  \(r.envVar): secret '\(r.secretName)' already exists; skipped (use --overwrite to replace)\n", stderr)
            case .failed(let why):
                fputs("❌ \(r.envVar): \(why)\n", stderr)
            }
        }
        let imported = results.filter(\.succeeded).count
        print("Imported \(imported) of \(results.count) variables into group '\(group)'.")
        if unprotected {
            fputs("⚠️  Stored WITHOUT Touch ID protection (unsigned build); run 'mima doctor'.\n", stderr)
        }
        if imported > 0 {
            fputs(
                "⚠️  These values sat in plaintext in \(file). If that file was ever committed, shared, or synced, rotate them.\n"
                    + "   mima left the file in place. Delete it once you've confirmed 'mima run --scrub \(group) -- <cmd>' works.\n",
                stderr
            )
        }
        if imported < results.count { throw ExitCode.failure }
    }
}
