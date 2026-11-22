import Foundation

/// Replaces secret values in a byte stream with `<mima:NAME>`, including
/// when a value is split across reads.
///
/// It holds back only a trailing fragment that could be the start of a
/// secret, so ordinary output (prompts without a newline, progress bars)
/// isn't delayed unless it happens to end in a secret's first bytes.
struct OutputMasker {
    /// Values shorter than this aren't masked: replacing every "1" or
    /// "dev" in the output would garble it and protect little.
    static let minimumLength = 4

    private struct Pattern {
        let bytes: [UInt8]
        let replacement: [UInt8]
    }

    private let patterns: [Pattern]
    private let firstBytes: Set<UInt8>
    private var pending: [UInt8] = []

    /// `secrets` maps environment variable name to value.
    init(secrets: [String: String]) {
        var patterns: [Pattern] = []
        for (name, value) in secrets where value.utf8.count >= Self.minimumLength {
            let replacement = Array("<mima:\(name)>".utf8)
            // The raw value, plus its JSON-escaped forms, since tools often
            // echo config or request bodies as JSON.
            for form in Set([value, jsonEscaped(value, escapeSlash: false), jsonEscaped(value, escapeSlash: true)]) {
                patterns.append(Pattern(bytes: Array(form.utf8), replacement: replacement))
            }
        }
        // Longest first, so a secret that contains another is masked whole.
        self.patterns = patterns.sorted { $0.bytes.count > $1.bytes.count }
        self.firstBytes = Set(patterns.compactMap(\.bytes.first))
    }

    /// Names whose values are too short to mask.
    static func unmaskedNames(_ secrets: [String: String]) -> [String] {
        secrets.filter { $0.value.utf8.count < minimumLength }.map(\.key).sorted()
    }

    /// Masks a chunk and returns the bytes that are safe to emit now.
    mutating func feed(_ chunk: [UInt8]) -> [UInt8] { process(chunk, final: false) }

    /// Flushes held bytes at end of stream. A held fragment that never
    /// completed a secret is emitted as is.
    mutating func finish() -> [UInt8] { process([], final: true) }

    private mutating func process(_ chunk: [UInt8], final: Bool) -> [UInt8] {
        let buf = pending + chunk
        pending = []
        var out: [UInt8] = []
        out.reserveCapacity(buf.count)
        var i = 0
        scan: while i < buf.count {
            if firstBytes.contains(buf[i]) {
                let remaining = buf.count - i
                for p in patterns {
                    if remaining >= p.bytes.count {
                        if buf[i..<(i + p.bytes.count)].elementsEqual(p.bytes) {
                            out += p.replacement
                            i += p.bytes.count
                            continue scan
                        }
                    } else if !final && p.bytes.starts(with: buf[i...]) {
                        // Could be the start of a secret that finishes in
                        // the next chunk: hold it.
                        pending = Array(buf[i...])
                        return out
                    }
                }
            }
            out.append(buf[i])
            i += 1
        }
        return out
    }
}

private func jsonEscaped(_ s: String, escapeSlash: Bool) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "/" where escapeSlash: out += "\\/"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}
