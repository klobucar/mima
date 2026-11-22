import Foundation
import LocalAuthentication
import MimaLib

class MockKeychain: KeychainProvider {
    var items: [String: Data] = [:]

    var protection: KeychainProtection = .userPresence

    @discardableResult
    func add(key: String, value: Data) throws -> KeychainProtection {
        if items[key] != nil { throw KeychainError.duplicateEntry }
        items[key] = value
        return protection
    }

    func get(key: String, context: LAContext?) throws -> Data {
        guard let data = items[key] else { throw KeychainError.itemNotFound }
        return data
    }

    func update(key: String, value: Data) throws {
        guard items[key] != nil else { throw KeychainError.itemNotFound }
        items[key] = value
    }

    func delete(key: String) throws {
        guard items[key] != nil else { throw KeychainError.itemNotFound }
        items[key] = nil
    }

    func list() throws -> [String] {
        return Array(items.keys)
    }
}
