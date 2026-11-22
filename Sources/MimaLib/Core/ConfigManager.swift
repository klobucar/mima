import Foundation
import Yams

public struct MimaConfig: Codable {
    public var groups: [String: [String: String]] = [:]
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
    
    public func link(group: String, envVar: String, secretName: String) throws {
        var config = try load()
        
        if config.groups[group] == nil {
            config.groups[group] = [:]
        }
        
        config.groups[group]?[envVar] = secretName
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
    
    public func getSecrets(for group: String) throws -> [String: String] {
        let config = try load()
        return config.groups[group] ?? [:]
    }
}
