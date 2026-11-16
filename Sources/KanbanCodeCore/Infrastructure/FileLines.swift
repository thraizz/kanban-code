import Foundation

/// Newline-delimited lines read from a file in large blocks.
///
/// `FileHandle.bytes.lines` walks the file one byte at a time through an async
/// iterator, which costs roughly a fifth of a second per megabyte. Session
/// transcripts routinely pass a hundred megabytes, so a palette search that
/// scans them was spending twenty seconds on a single file. Reading in blocks
/// and splitting on newlines does the same job at I/O speed.
///
/// Blank lines are dropped, which every `.jsonl` reader here wants anyway, and a
/// trailing carriage return is trimmed so CRLF files parse.
public struct FileLines: AsyncSequence, Sendable {
    public typealias Element = String

    public static let defaultChunkSize = 1 << 20

    private let handle: FileHandle
    private let chunkSize: Int

    public init(handle: FileHandle, chunkSize: Int = FileLines.defaultChunkSize) {
        self.handle = handle
        self.chunkSize = Swift.max(4096, chunkSize)
    }

    /// A line together with where it starts in the file.
    ///
    /// Byte offsets cannot be recovered from the lines alone, because blank
    /// lines are dropped and a trailing carriage return is trimmed. They are
    /// what a transcript row is identified by, so a reader that has to line its
    /// results up with another one needs them counted while the split happens.
    public struct Record: Sendable {
        public let byteOffset: Int
        public let text: String
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let handle: FileHandle
        private let chunkSize: Int
        private var buffer = Data()
        private var ready: [Record] = []
        private var readyIndex = 0
        private var reachedEnd = false
        /// Where the next byte staged from `buffer` sits in the file.
        private var blockOffset: Int

        init(handle: FileHandle, chunkSize: Int) {
            self.handle = handle
            self.chunkSize = chunkSize
            self.blockOffset = Int((try? handle.offset()) ?? 0)
        }

        public mutating func next() async throws -> String? {
            try await self.nextRecord()?.text
        }

        public mutating func nextRecord() async throws -> Record? {
            while true {
                if readyIndex < ready.count {
                    defer { readyIndex += 1 }
                    return ready[readyIndex]
                }
                if reachedEnd { return nil }

                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty {
                    reachedEnd = true
                    guard !buffer.isEmpty else { return nil }
                    stage(buffer, consumed: buffer.count)
                    buffer = Data()
                    continue
                }

                buffer.append(chunk)
                // Split only up to the last newline: that keeps every decoded
                // block whole-lines, so a multi-byte character can never be cut
                // across two chunks.
                guard let lastNewline = Self.lastNewlineOffset(in: buffer) else { continue }
                // The newline itself is not part of the staged block but is part
                // of what the file has moved on past.
                stage(buffer.prefix(lastNewline), consumed: lastNewline + 1)
                buffer = buffer.count > lastNewline + 1
                    ? Data(buffer.dropFirst(lastNewline + 1))
                    : Data()
                await Task.yield()
            }
        }

        /// Offset of the last newline byte, scanned over raw memory. `Data`'s
        /// Collection conformance is slow enough that going through it here
        /// costs more than reading the file did.
        static func lastNewlineOffset(in data: Data) -> Int? {
            data.withUnsafeBytes { raw -> Int? in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                var index = raw.count - 1
                while index >= 0 {
                    if base[index] == UInt8(ascii: "\n") { return index }
                    index -= 1
                }
                return nil
            }
        }

        /// Splits on the newline *byte*. Swift treats "\r\n" as a single
        /// Character, so splitting the decoded string leaves CRLF lines joined.
        private mutating func stage(_ block: Data, consumed: Int) {
            let baseOffset = self.blockOffset
            var lines: [Record] = []
            block.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var start = 0
                while start < raw.count {
                    let found = memchr(base + start, Int32(UInt8(ascii: "\n")), raw.count - start)
                    let breakAt = found.map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? raw.count
                    var end = breakAt
                    if end > start, base[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                    if end > start {
                        lines.append(Record(
                            byteOffset: baseOffset + start,
                            text: String(
                                decoding: UnsafeBufferPointer(start: base + start, count: end - start),
                                as: UTF8.self
                            )
                        ))
                    }
                    start = breakAt + 1
                }
            }
            self.blockOffset += consumed
            ready = lines
            readyIndex = 0
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(handle: handle, chunkSize: chunkSize)
    }
}

/// The same lines, each with the byte offset it starts at.
public struct FileLineRecords: AsyncSequence, Sendable {
    public typealias Element = FileLines.Record

    private let lines: FileLines

    public init(lines: FileLines) {
        self.lines = lines
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var inner: FileLines.AsyncIterator

        public mutating func next() async throws -> FileLines.Record? {
            try await self.inner.nextRecord()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(inner: self.lines.makeAsyncIterator())
    }
}

extension FileHandle {
    /// Lines read in blocks. See ``FileLines`` for why this exists.
    public var blockLines: FileLines { FileLines(handle: self) }

    /// The same lines, each with where it starts in the file.
    public var blockLineRecords: FileLineRecords {
        FileLineRecords(lines: FileLines(handle: self))
    }

    /// The last `maxBytes` of the file as text, read to the end.
    ///
    /// Not `availableData` after a seek: on Linux that returns one `read()`,
    /// 4 KiB, so a 64 KiB tail was the 4 KiB that starts 64 KiB before the
    /// end, and the "last" line was an old one or none at all. The window's
    /// start can split a UTF-8 character; that first line is partial anyway,
    /// so the text is decoded leniently instead of failing as a whole.
    public func tailText(maxBytes: UInt64) -> String {
        let fileSize = seekToEndOfFile()
        seek(toFileOffset: fileSize - min(maxBytes, fileSize))
        let data = readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
