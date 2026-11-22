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
    
    func testUnlinkRemovesVariableAndEmptyGroup() throws {
        try manager.link(group: "g", envVar: "A", secretName: "s1")
        try manager.link(group: "g", envVar: "B", secretName: "s2")
        try manager.unlink(group: "g", envVar: "A")
        XCTAssertEqual(try manager.getSecrets(for: "g"), ["B": "s2"])
        try manager.unlink(group: "g", envVar: "B")
        XCTAssertNil(try manager.load().groups["g"], "an emptied group should disappear")
    }

    func testUnlinkAndRemoveReportMissingTargets() throws {
        try manager.link(group: "g", envVar: "A", secretName: "s1")
        XCTAssertThrowsError(try manager.unlink(group: "nope", envVar: "A"))
        XCTAssertThrowsError(try manager.unlink(group: "g", envVar: "NOPE"))
        XCTAssertThrowsError(try manager.removeGroup("nope"))
    }

    func testRemoveGroupLeavesOthers() throws {
        try manager.link(group: "g1", envVar: "A", secretName: "s1")
        try manager.link(group: "g2", envVar: "B", secretName: "s2")
        try manager.removeGroup("g1")
        XCTAssertEqual(Array(try manager.load().groups.keys), ["g2"])
    }

    func testMultipleGroups() throws {
        try manager.link(group: "g1", envVar: "K1", secretName: "S1")
        try manager.link(group: "g2", envVar: "K2", secretName: "S2")
        
        let config = try manager.load()
        XCTAssertEqual(config.groups.count, 2)
    }
}
