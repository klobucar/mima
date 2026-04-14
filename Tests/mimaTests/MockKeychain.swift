import Foundation
import LocalAuthentication
import MimaLib

class MockKeychain: KeychainProvider {
    var items: [String: Data] = [:]

    func add(key: String, value: Data) throws {
        if items[key] != nil { throw KeychainError.duplicateEntry }
        items[key] = value
    }

    func get(key: String, context: LAContext?) throws -> Data {
        guard let data = items[key] else { throw KeychainError.itemNotFound }
        return data
    }

    func delete(key: String) throws {
        guard items[key] != nil else { throw KeychainError.itemNotFound }
        items[key] = nil
    }

    func list() throws -> [String] {
        return Array(items.keys)
    }
}
