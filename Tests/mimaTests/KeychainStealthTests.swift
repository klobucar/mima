import XCTest
@testable import MimaLib

final class KeychainStealthTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Inject Mock
        KeychainManager.shared = MockKeychain()
    }
    
    override func tearDown() {
        // Reset to native (though process isolation usually handles this, good practice)
        KeychainManager.shared = NativeKeychain()
        super.tearDown()
    }
    
    func testAddAndGet() throws {
        let key = "test-secret"
        let value = "secret-value".data(using: .utf8)!
        
        try KeychainManager.shared.add(key: key, value: value)
        
        let retrieved = try KeychainManager.shared.get(key: key, context: nil)
        XCTAssertEqual(retrieved, value)
    }
    
    func testList() throws {
        try KeychainManager.shared.add(key: "A", value: Data())
        try KeychainManager.shared.add(key: "B", value: Data())
        
        let list = try KeychainManager.shared.list()
        XCTAssertTrue(list.contains("A"))
        XCTAssertTrue(list.contains("B"))
        XCTAssertEqual(list.count, 2)
    }
}
