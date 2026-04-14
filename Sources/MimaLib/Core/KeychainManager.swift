import Foundation
import Security
import LocalAuthentication

public protocol KeychainProvider {
    func add(key: String, value: Data) throws
    func get(key: String, context: LAContext?) throws -> Data
    func delete(key: String) throws
    func list() throws -> [String]
}

public enum KeychainError: Error {
    case duplicateEntry
    case unknown(OSStatus)
    case itemNotFound
    case invalidData
    case interactionNotAllowed
}

public class KeychainManager {
    public static var shared: KeychainProvider = NativeKeychain()
}

public class NativeKeychain: KeychainProvider {
    // Service name for namespacing
    private let service = "com.mima.cli"
    
    public init() {}

    public func add(key: String, value: Data) throws {
        // Create Access Control for Touch ID (User Presence)
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: value,
            kSecAttrAccessControl as String: accessControl
        ]

        var status = SecItemAdd(query as CFDictionary, nil)
        
        // Fallback for Ad-hoc signing (Error -34018)
        if status == errSecMissingEntitlement {
            print("⚠️ Warning: Biometric security unavailable (Ad-hoc signing). Falling back to standard keychain security.")
            var fallbackQuery = query
            fallbackQuery.removeValue(forKey: kSecAttrAccessControl as String)
            status = SecItemAdd(fallbackQuery as CFDictionary, nil)
        }
        
        guard status != errSecDuplicateItem else { throw KeychainError.duplicateEntry }
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
    }

    public func get(key: String, context: LAContext? = nil) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        if let context = context {
            query[kSecUseAuthenticationContext as String] = context
        } else {
             // Basic interaction if no context provided (might prompt individually)
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
        guard let data = item as? Data else { throw KeychainError.invalidData }
        
        return data
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        
        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
    }

    public func list() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
        
        guard let result = items as? [[String: Any]] else { return [] }
        
        return result.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
