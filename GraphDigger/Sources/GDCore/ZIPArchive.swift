import Foundation

/// A minimal ZIP writer — just enough of the format to build an OOXML package.
///
/// ## Stored, not deflated
///
/// Every entry is written with compression method 0 (`store`). Foundation has no
/// deflate API, and writing one by hand for a few kilobytes of XML would be a
/// large amount of code — and a large number of ways to produce an archive that
/// some reader rejects — in exchange for a smaller file nobody is going to
/// notice. `store` is part of the format, not an approximation of it: a stored
/// archive is a legal ZIP that every reader opens, and both Excel and Numbers
/// accept a stored XLSX. The alternative, deferring to `/usr/bin/zip`, would
/// mean spawning a process and carrying an untestable error path.
///
/// ## What is here
///
/// Local file headers, the central directory, and the end-of-central-directory
/// record — the three parts a reader walks. No data descriptors, no encryption,
/// no ZIP64, no directory entries: an XLSX package is a flat list of a handful
/// of small files, all of them far below the 4 GB and 65535-entry limits that
/// would need the rest. Entry names are ASCII, which is what lets the flags
/// field be zero rather than setting the UTF-8 bit.
///
/// Timestamps are taken from a `Date` the caller supplies, so the output is
/// reproducible when one is passed — which is what lets a test compare bytes.
public enum ZIPArchive {

    /// One file in the archive. `name` is a forward-slash path, as the format
    /// requires; a leading slash is not added and must not be present.
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let data: Data
        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// The bytes of a complete archive.
    public static func data(entries: [Entry], modified: Date = Date()) -> Data {
        let stamp = dosStamp(modified)
        var body = Data()
        var directory = Data()

        for entry in entries {
            let name = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(body.count)

            // Local file header. The two sizes are equal because nothing is
            // compressed, and the CRC is the file's own — a reader that streams
            // entries checks it as it goes.
            body.append(uint32(0x04034B50))          // local file header
            body.append(uint16(20))                  // version needed: 2.0
            body.append(uint16(0))                   // flags
            body.append(uint16(0))                   // method: stored
            body.append(uint16(stamp.time))
            body.append(uint16(stamp.date))
            body.append(uint32(crc))
            body.append(uint32(UInt32(entry.data.count)))
            body.append(uint32(UInt32(entry.data.count)))
            body.append(uint16(UInt16(name.count)))
            body.append(uint16(0))                   // extra field length
            body.append(contentsOf: name)
            body.append(entry.data)

            // Central directory record: the same facts again, plus where the
            // local header sits, which is how a reader jumps straight to an entry
            // instead of walking the whole file.
            directory.append(uint32(0x02014B50))
            directory.append(uint16(20))             // version made by
            directory.append(uint16(20))             // version needed
            directory.append(uint16(0))              // flags
            directory.append(uint16(0))              // method: stored
            directory.append(uint16(stamp.time))
            directory.append(uint16(stamp.date))
            directory.append(uint32(crc))
            directory.append(uint32(UInt32(entry.data.count)))
            directory.append(uint32(UInt32(entry.data.count)))
            directory.append(uint16(UInt16(name.count)))
            directory.append(uint16(0))              // extra field length
            directory.append(uint16(0))              // comment length
            directory.append(uint16(0))              // disk number start
            directory.append(uint16(0))              // internal attributes
            directory.append(uint32(0))              // external attributes
            directory.append(uint32(offset))
            directory.append(contentsOf: name)
        }

        let directoryOffset = UInt32(body.count)
        var out = body
        out.append(directory)

        // End of central directory. No comment and no spanning, so the fields
        // that would describe those are zero.
        out.append(uint32(0x06054B50))
        out.append(uint16(0))                        // this disk
        out.append(uint16(0))                        // disk with the directory
        out.append(uint16(UInt16(entries.count)))    // entries on this disk
        out.append(uint16(UInt16(entries.count)))    // entries in total
        out.append(uint32(UInt32(directory.count)))
        out.append(uint32(directoryOffset))
        out.append(uint16(0))                        // comment length
        return out
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1
            }
            return value
        }
    }()

    /// The ZIP checksum: CRC-32 with the reflected polynomial `0xEDB88320`,
    /// pre- and post-inverted.
    ///
    /// Public because it is the one part of this file with an authoritative
    /// external answer — the standard check value for `"123456789"` is
    /// `0xCBF43926` — and a test that pins it is worth more than one that only
    /// agrees with the writer next to it.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Little-endian helpers
    //
    // Spelled out byte by byte rather than through `withUnsafeBytes(of:)` so the
    // order is stated in the source instead of inferred from the host. ZIP is
    // little-endian, and reading it the other way would be a bug that only shows
    // up on hardware nobody here has.

    /// Returned as `Data` rather than `[UInt8]` so the call sites can use
    /// `append` directly — the archive is assembled byte by byte and the labels
    /// `append(contentsOf:)` would need at every field add nothing.
    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    /// MS-DOS date and time, which is what a ZIP entry carries: the date packed
    /// as `(year-1980) << 9 | month << 5 | day`, the time as
    /// `hour << 11 | minute << 5 | second/2`.
    ///
    /// The seconds field holds half-seconds, so an odd second is rounded down —
    /// a fact about the format, not a decision here. Years before 1980 cannot be
    /// represented and clamp to it.
    private static func dosStamp(_ date: Date) -> (date: UInt16, time: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let packedDate = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        let packedTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        return (packedDate, packedTime)
    }
}
