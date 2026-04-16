import XCTest
@testable import MimaLib

final class PathLookupTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mima-pathlookup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeExecutable(in dir: String, named name: String) throws -> String {
        let dirURL = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let fileURL = dirURL.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        return fileURL.path
    }

    private func makePlainFile(in dir: String, named name: String) throws -> String {
        let dirURL = root.appendingPathComponent(dir)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let fileURL = dirURL.appendingPathComponent(name)
        try "not executable".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        return fileURL.path
    }

    func testFindsExecutableInFirstDirectory() throws {
        let expected = try makeExecutable(in: "a", named: "tool")
        let pathEnv = "\(root.appendingPathComponent("a").path):\(root.appendingPathComponent("b").path)"
        XCTAssertEqual(resolveExecutable("tool", pathEnv: pathEnv), expected)
    }

    func testFindsExecutableInLaterDirectory() throws {
        let expected = try makeExecutable(in: "b", named: "tool")
        let pathEnv = "\(root.appendingPathComponent("a").path):\(root.appendingPathComponent("b").path)"
        XCTAssertEqual(resolveExecutable("tool", pathEnv: pathEnv), expected)
    }

    func testFirstMatchWins() throws {
        let first = try makeExecutable(in: "a", named: "tool")
        _ = try makeExecutable(in: "b", named: "tool")
        let pathEnv = "\(root.appendingPathComponent("a").path):\(root.appendingPathComponent("b").path)"
        XCTAssertEqual(resolveExecutable("tool", pathEnv: pathEnv), first)
    }

    func testSkipsNonExecutableFiles() throws {
        _ = try makePlainFile(in: "a", named: "tool")
        let expected = try makeExecutable(in: "b", named: "tool")
        let pathEnv = "\(root.appendingPathComponent("a").path):\(root.appendingPathComponent("b").path)"
        XCTAssertEqual(resolveExecutable("tool", pathEnv: pathEnv), expected)
    }

    func testReturnsNilWhenNotFound() {
        let pathEnv = "\(root.appendingPathComponent("a").path):\(root.appendingPathComponent("b").path)"
        XCTAssertNil(resolveExecutable("nope", pathEnv: pathEnv))
    }

    func testEmptyPathEnv() {
        XCTAssertNil(resolveExecutable("tool", pathEnv: ""))
    }

    func testIgnoresEmptyComponents() throws {
        let expected = try makeExecutable(in: "a", named: "tool")
        let pathEnv = "::\(root.appendingPathComponent("a").path):"
        XCTAssertEqual(resolveExecutable("tool", pathEnv: pathEnv), expected)
    }
}
