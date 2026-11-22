import Foundation

/// Outcome of importing one variable from a `.env` file.
struct ImportResult: Equatable {
    enum Status: Equatable {
        case added(KeychainProtection)
        case updated
        case skippedExisting
        case failed(String)
    }
    let envVar: String
    let secretName: String
    let status: Status

    var succeeded: Bool {
        switch status {
        case .added, .updated: return true
        case .skippedExisting, .failed: return false
        }
    }
}

/// Secret name for an imported variable: `<prefix>-<var>`, lowercased,
/// with `_` replaced by `-`. For example, prefix `myapp` and `STRIPE_KEY`
/// give `myapp-stripe-key`.
func importedSecretName(prefix: String, envVar: String) -> String {
    "\(prefix)-\(envVar.lowercased().replacingOccurrences(of: "_", with: "-"))"
}

/// Stores each pair in the Keychain and links it into `group`. A variable
/// is linked only after its secret is stored, so a failure never leaves a
/// mapping that points at nothing.
func importDotEnv(
    _ pairs: [(key: String, value: String)],
    group: String,
    prefix: String,
    overwrite: Bool,
    keychain: KeychainProvider,
    config: ConfigManager
) throws -> [ImportResult] {
    var results: [ImportResult] = []
    for (envVar, value) in pairs {
        let name = importedSecretName(prefix: prefix, envVar: envVar)
        let data = Data(value.utf8)
        let status: ImportResult.Status
        do {
            try validateSecretValue(data)
            do {
                status = .added(try keychain.add(key: name, value: data))
            } catch KeychainError.duplicateEntry {
                guard overwrite else {
                    results.append(ImportResult(envVar: envVar, secretName: name, status: .skippedExisting))
                    continue
                }
                try keychain.update(key: name, value: data)
                status = .updated
            }
        } catch {
            results.append(ImportResult(envVar: envVar, secretName: name, status: .failed("\(error)")))
            continue
        }
        try config.link(group: group, envVar: envVar, secretName: name)
        results.append(ImportResult(envVar: envVar, secretName: name, status: status))
    }
    return results
}
