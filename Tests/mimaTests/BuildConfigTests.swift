import XCTest

/// Guards the signing inputs. The original entitlements.plist used Xcode's
/// `$(AppIdentifierPrefix)`, which codesign embeds literally. AMFI then
/// killed every `make build` binary at launch.
final class BuildConfigTests: XCTestCase {
    private func repoFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testEntitlementsTemplateUsesSignScriptPlaceholders() throws {
        let plist = try repoFile("entitlements.plist")
        XCTAssertFalse(plist.contains("$("), "codesign does not expand Xcode build variables")
        XCTAssertTrue(plist.contains("<string>@TEAM_ID@.@BUNDLE_ID@</string>"))
    }

    func testEntitlementsDoNotAllowDebuggerAttach() throws {
        // get-task-allow would let any process running as the user attach
        // to mima and read unlocked secrets from memory.
        XCTAssertFalse(try repoFile("entitlements.plist").contains("get-task-allow"))
    }

    func testRenderedTemplatesAreValidPlists() throws {
        for (file, replacements) in [
            ("entitlements.plist", ["@TEAM_ID@": "ABCDE12345", "@BUNDLE_ID@": "com.mima.cli"]),
            ("scripts/Info.plist.in", ["@BUNDLE_ID@": "com.mima.cli"]),
        ] {
            var text = try repoFile(file)
            for (k, v) in replacements { text = text.replacingOccurrences(of: k, with: v) }
            XCTAssertFalse(text.contains("@"), "\(file) has an unrendered placeholder")
            XCTAssertNoThrow(
                try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil),
                "\(file) is not a valid plist after rendering"
            )
        }
    }
}
