import XCTest
@testable import MimaLib

final class OutputMaskerTests: XCTestCase {
    private func mask(_ secrets: [String: String], chunks: [String]) -> String {
        var m = OutputMasker(secrets: secrets)
        var out: [UInt8] = []
        for c in chunks { out += m.feed(Array(c.utf8)) }
        out += m.finish()
        return String(decoding: out, as: UTF8.self)
    }

    func testMasksWholeValue() {
        XCTAssertEqual(mask(["TOKEN": "sk-live-123"], chunks: ["auth: sk-live-123\n"]), "auth: <mima:TOKEN>\n")
    }

    /// A value split across reads at any byte offset must still be masked,
    /// and no byte of it may be emitted early.
    func testEverySplitPointIsMasked() {
        let secret = "sk-proj-AbC123xyz"
        let text = "before \(secret) after"
        let bytes = Array(text.utf8)
        for cut in 0...bytes.count {
            for cut2 in cut...bytes.count {
                var m = OutputMasker(secrets: ["K": secret])
                var out = m.feed(Array(bytes[0..<cut]))
                out += m.feed(Array(bytes[cut..<cut2]))
                out += m.feed(Array(bytes[cut2...]))
                out += m.finish()
                XCTAssertEqual(String(decoding: out, as: UTF8.self), "before <mima:K> after", "cuts at \(cut),\(cut2)")
            }
        }
    }

    func testByteByByteStream() {
        let text = "x=sk-proj-AbC123xyz;y=sk-proj-AbC123xyz"
        XCTAssertEqual(mask(["K": "sk-proj-AbC123xyz"], chunks: text.map { String($0) }), "x=<mima:K>;y=<mima:K>")
    }

    func testOrdinaryOutputIsNotHeldBack() {
        var m = OutputMasker(secrets: ["K": "sk-proj-AbC123xyz"])
        XCTAssertEqual(m.feed(Array("Password: ".utf8)), Array("Password: ".utf8), "a prompt without a newline must flush immediately")
    }

    func testFragmentThatNeverCompletesIsFlushedAtEnd() {
        XCTAssertEqual(mask(["K": "sk-proj-AbC123xyz"], chunks: ["ends with sk-pr"]), "ends with sk-pr")
    }

    func testLongestSecretWinsWhenOneContainsAnother() {
        let out = mask(["SHORT": "abcd", "LONG": "abcd-efgh"], chunks: ["abcd-efgh and abcd"])
        XCTAssertEqual(out, "<mima:LONG> and <mima:SHORT>")
    }

    func testJSONEscapedFormsAreMasked() {
        let secret = #"p@ss"w/rd\1"#
        let json = #"{"password":"p@ss\"w/rd\\1","alt":"p@ss\"w\/rd\\1"}"#
        XCTAssertEqual(mask(["PW": secret], chunks: [json]), #"{"password":"<mima:PW>","alt":"<mima:PW>"}"#)
    }

    func testShortValuesAreNotMaskedButReported() {
        let secrets = ["DEBUG": "1", "TOKEN": "sk-live-123"]
        XCTAssertEqual(mask(secrets, chunks: ["1 sk-live-123"]), "1 <mima:TOKEN>")
        XCTAssertEqual(OutputMasker.unmaskedNames(secrets), ["DEBUG"])
    }

    func testMultibyteValues() {
        XCTAssertEqual(mask(["K": "pässwörd😀"], chunks: ["x pässw", "örd😀 y"]), "x <mima:K> y")
    }
}
