import Foundation

/// Splits a stream of bytes into lines. Bytes wait until their line is
/// complete, so a character split across two reads (Hebrew, emoji) stays whole.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// Adds bytes and returns the lines they complete, without line endings.
    public mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
            var line = pending[start..<newline]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            lines.append(Data(line))
            start = pending.index(after: newline)
        }
        pending = Data(pending[start...])
        return lines
    }

    /// The last line, when the stream ended without a line break.
    public mutating func finish() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}
