import Foundation
import Security
import LocalAuthentication

/// The protection a stored secret actually received.
public enum KeychainProtection: Equatable {
    /// Data protection keychain, `.userPresence` ACL: reading needs
    /// Touch ID or the login password.
    case userPresence
    /// Legacy file-based keychain with no ACL: encrypted at rest, but any
    /// process running as you can read it without a prompt.
    case none
}

public protocol KeychainProvider {
    @discardableResult
    func add(key: String, value: Data) throws -> KeychainProtection
    func get(key: String, context: LAContext?) throws -> Data
    func delete(key: String) throws
    func list() throws -> [String]
}

public enum KeychainError: Error, CustomStringConvertible {
    case duplicateEntry
    case unknown(OSStatus)
    case itemNotFound
    case invalidData
    case interactionNotAllowed
    /// The binary is entitled for Touch ID-protected items, but this
    /// secret exists only as an older unprotected item. mima refuses to
    /// read it, so a planted item can't stand in for a real one.
    case unprotectedItemOnly(String)

    public var description: String {
        switch self {
        case .duplicateEntry: return "a secret with that name already exists"
        case .itemNotFound: return "secret not found"
        case .invalidData: return "stored value is not readable data"
        case .interactionNotAllowed: return "authentication is not possible right now"
        case .unprotectedItemOnly(let name):
            return "'\(name)' exists only as an unprotected item, stored before mima was signed for Touch ID. "
                + "Run 'mima secret remove \(name)' and add it again to protect it."
        case .unknown(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "\(message) (OSStatus \(status))"
        }
    }
}

public class KeychainManager {
    public static var shared: KeychainProvider = NativeKeychain()
}

public class NativeKeychain: KeychainProvider {
    // Service name for namespacing
    static let service = "com.mima.cli"
    private var service: String { Self.service }

    /// True when this binary carries a `keychain-access-groups`
    /// entitlement, meaning it was signed with a team identity and a
    /// provisioning profile (see `make install`). Only then can it use
    /// the data protection keychain, where `.userPresence` ACLs live.
    ///
    /// Decided up front from the entitlement, not by trial and error.
    /// Reads from an unentitled binary report "not found" rather than
    /// "missing entitlement", so probing gives misleading answers.
    public let isEntitled: Bool

    public init() {
        isEntitled = Self.hasAccessGroupEntitlement()
    }

    public static func hasAccessGroupEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil),
              let groups = value as? [String]
        else { return false }
        return !groups.isEmpty
    }

    /// Every query names its keychain explicitly. On macOS, leaving
    /// `kSecUseDataProtectionKeychain` unset targets the legacy keychain
    /// even for an entitled binary.
    private func query(_ key: String?, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
        if let key { q[kSecAttrAccount as String] = key }
        return q
    }

    @discardableResult
    public func add(key: String, value: Data) throws -> KeychainProtection {
        var q = query(key, dataProtection: isEntitled)
        q[kSecValueData as String] = value

        let protection: KeychainProtection
        if isEntitled {
            var error: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                .userPresence,
                &error
            ) else {
                throw error!.takeRetainedValue() as Error
            }
            q[kSecAttrAccessControl as String] = accessControl
            protection = .userPresence
        } else {
            protection = .none
        }

        // No silent downgrade: an entitled binary that fails to store a
        // protected item reports the error rather than retrying without
        // the ACL.
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status != errSecDuplicateItem else { throw KeychainError.duplicateEntry }
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
        return protection
    }

    public func get(key: String, context: LAContext? = nil) throws -> Data {
        var q = query(key, dataProtection: isEntitled)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            q[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)

        if status == errSecItemNotFound {
            if isEntitled && legacyItemExists(key) { throw KeychainError.unprotectedItemOnly(key) }
            throw KeychainError.itemNotFound
        }
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
        guard let data = item as? Data else { throw KeychainError.invalidData }
        return data
    }

    /// Removes the secret from the keychain this build uses. An entitled
    /// build also removes a leftover unprotected item with the same
    /// name, which is how such items get migrated: remove, then add.
    public func delete(key: String) throws {
        var removed = false
        for dataProtection in isEntitled ? [true, false] : [false] {
            let status = SecItemDelete(query(key, dataProtection: dataProtection) as CFDictionary)
            if status == errSecSuccess { removed = true; continue }
            guard status == errSecItemNotFound else { throw KeychainError.unknown(status) }
        }
        guard removed else { throw KeychainError.itemNotFound }
    }

    public func list() throws -> [String] {
        try accounts(dataProtection: isEntitled)
    }

    /// Names of secrets stored without an ACL in the legacy keychain.
    /// For an entitled build these are invisible to `get` and need
    /// re-adding. For an unentitled build this is every secret.
    public func listUnprotected() throws -> [String] {
        try accounts(dataProtection: false)
    }

    /// Stores and deletes a throwaway item behind a `.userPresence` ACL.
    /// That proves the protected path works end to end without reading
    /// anything, so no prompt appears. Returns nil on success, or the
    /// failing OSStatus.
    public func probeProtectedStorage() -> OSStatus? {
        guard isEntitled else { return errSecMissingEntitlement }
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil
        ) else { return errSecParam }
        var q = query("mima-doctor-probe-\(UUID().uuidString)", dataProtection: true)
        let deleteQuery = q
        q[kSecValueData as String] = Data("probe".utf8)
        q[kSecAttrAccessControl as String] = accessControl
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { return status }
        SecItemDelete(deleteQuery as CFDictionary)
        return nil
    }

    private func legacyItemExists(_ key: String) -> Bool {
        var q = query(key, dataProtection: false)
        q[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }

    private func accounts(dataProtection: Bool) throws -> [String] {
        var q = query(nil, dataProtection: dataProtection)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll

        var items: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unknown(status) }
        guard let result = items as? [[String: Any]] else { return [] }
        return result.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}
