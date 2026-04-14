import XCTest
@testable import MimaLib

final class ConfigManagerTests: XCTestCase {
    var tempURL: URL!
    var manager: ConfigManager!
    
    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("yaml")
        manager = ConfigManager(configURL: tempURL)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }
    
    func testLinkAndLoad() throws {
        try manager.link(group: "test", envVar: "KEY", secretName: "secret")
        
        let config = try manager.load()
        XCTAssertEqual(config.groups["test"]?["KEY"], "secret")
    }
    
    func testPersistence() throws {
        try manager.link(group: "g1", envVar: "K", secretName: "S")
        
        // New instance same path
        let manager2 = ConfigManager(configURL: tempURL)
        let config = try manager2.load()
        XCTAssertEqual(config.groups["g1"]?["K"], "S")
    }
    
    func testMultipleGroups() throws {
        try manager.link(group: "g1", envVar: "K1", secretName: "S1")
        try manager.link(group: "g2", envVar: "K2", secretName: "S2")
        
        let config = try manager.load()
        XCTAssertEqual(config.groups.count, 2)
    }
}
