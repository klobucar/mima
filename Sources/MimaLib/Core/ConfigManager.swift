import Foundation
import Yams

/// One environment variable's source.
///
/// In YAML, the short form `ENV: secret-name` is the common case. The long
/// form adds hosts for `mima run --claude` credential masking:
///
///     ENV: {secret: secret-name, hosts: [api.github.com]}
///
/// A mapping without hosts is always written back in the short form, so
/// existing configs round-trip unchanged.
public struct SecretMapping: Codable, Equatable, ExpressibleByStringLiteral {
    public var secret: String
    public var hosts: [String]

    public init(secret: String, hosts: [String] = []) {
        self.secret = secret
        self.hosts = hosts
    }

    public init(stringLiteral value: String) { self.init(secret: value) }

    private enum CodingKeys: String, CodingKey { case secret, hosts }

    public init(from decoder: Decoder) throws {
        if let short = try? decoder.singleValueContainer().decode(String.self) {
            self.init(secret: short)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(secret: try c.decode(String.self, forKey: .secret), hosts: try c.decodeIfPresent([String].self, forKey: .hosts) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        if hosts.isEmpty {
            var c = encoder.singleValueContainer()
            try c.encode(secret)
        } else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(secret, forKey: .secret)
            try c.encode(hosts, forKey: .hosts)
        }
    }
}

public struct MimaConfig: Codable {
    public var groups: [String: [String: SecretMapping]] = [:]
    public init() {}
}

public enum ConfigError: Error, CustomStringConvertible {
    case groupNotFound(String)
    case mappingNotFound(group: String, envVar: String)

    public var description: String {
        switch self {
        case .groupNotFound(let g): return "no group named \(g.debugDescription)"
        case .mappingNotFound(let g, let v): return "group \(g.debugDescription) has no variable \(v.debugDescription)"
        }
    }
}

public class ConfigManager {
    public static let shared = ConfigManager()
    
    private let fileManager = FileManager.default
    private let customConfigURL: URL?
    
    private var configPath: URL {
        if let custom = customConfigURL { return custom }
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".mima.yaml")
    }
    
    public init(configURL: URL? = nil) {
        self.customConfigURL = configURL
    }
    
    public func load() throws -> MimaConfig {
        guard fileManager.fileExists(atPath: configPath.path) else {
            return MimaConfig()
        }
        
        let data = try Data(contentsOf: configPath)
        let decoder = YAMLDecoder()
        return try decoder.decode(MimaConfig.self, from: data)
    }
    
    public func save(_ config: MimaConfig) throws {
        let encoder = YAMLEncoder()
        let yamlString = try encoder.encode(config)
        
        // Atomic Write Strategy:
        // 1. Write to a temporary file in the same directory (to ensure atomic move support)
        // 2. Rename temporary file to target file
        
        let tempUUID = UUID().uuidString
        let tempURL = configPath.deletingLastPathComponent().appendingPathComponent(".mima.yaml.tmp.\(tempUUID)")
        
        try yamlString.write(to: tempURL, atomically: true, encoding: .utf8)
        
        // Atomic replace
        _ = try fileManager.replaceItemAt(configPath, withItemAt: tempURL, backupItemName: nil, options: .usingNewMetadataOnly)
    }
    
    public func link(group: String, envVar: String, secretName: String, hosts: [String] = []) throws {
        var config = try load()
        config.groups[group, default: [:]][envVar] = SecretMapping(secret: secretName, hosts: hosts)
        try save(config)
    }
    
    /// Removes one variable from a group. A group left empty is removed.
    public func unlink(group: String, envVar: String) throws {
        var config = try load()
        guard var mappings = config.groups[group] else { throw ConfigError.groupNotFound(group) }
        guard mappings.removeValue(forKey: envVar) != nil else {
            throw ConfigError.mappingNotFound(group: group, envVar: envVar)
        }
        config.groups[group] = mappings.isEmpty ? nil : mappings
        try save(config)
    }

    /// Removes a group's mappings. The secrets stay in the Keychain.
    public func removeGroup(_ group: String) throws {
        var config = try load()
        guard config.groups.removeValue(forKey: group) != nil else { throw ConfigError.groupNotFound(group) }
        try save(config)
    }

    public func list() throws -> String {
        let config = try load()
        let encoder = YAMLEncoder()
        return try encoder.encode(config)
    }
    
    /// Env var → secret name for a group.
    public func getSecrets(for group: String) throws -> [String: String] {
        try getMappings(for: group).mapValues(\.secret)
    }

    /// Env var → full mapping (secret name and hosts) for a group.
    public func getMappings(for group: String) throws -> [String: SecretMapping] {
        try load().groups[group] ?? [:]
    }
}
