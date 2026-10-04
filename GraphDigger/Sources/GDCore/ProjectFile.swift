import Foundation

// MARK: - What a project file says about itself

/// The image a project carries, described without having to decode it.
///
/// Recorded so the file is self-describing: a reader — this app, a future one,
/// or a person with `xxd` — can say what is in the file before paying for a
/// decode, and the window can put a name up while the bytes are still on their
/// way in.
public struct ProjectImageInfo: Codable, Equatable, Sendable {

    /// The name the image was opened under.
    ///
    /// Optional because an image can arrive from somewhere with no name at all.
    /// When it is there it serves two purposes: the window title, and the stem a
    /// 「项目另存为」 panel offers, so saving a project named after the chart
    /// needs no typing.
    public var fileName: String?

    /// Pixel dimensions of the image the header describes.
    ///
    /// Stored rather than derived because deriving them means decoding the image,
    /// which is the thing this struct exists to avoid.
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(fileName: String? = nil, pixelWidth: Int, pixelHeight: Int) {
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Everything in a project file except the image bytes.
///
/// **Every field here must stay optional, or be given a default, for the life of
/// the format.** Decoding is synthesised, so an absent key is only tolerated for
/// a property whose type is `Optional` — which makes "add new fields as
/// optionals" the one rule that lets a newer build read an older file. The
/// reverse direction is not attempted: a file written by a newer *format* is
/// rejected outright by the version in the prologue rather than half-read.
public struct ProjectHeader: Codable, Equatable, Sendable {

    /// The app version that wrote the file. Informational — nothing branches on
    /// it — but it is the first thing wanted when a file misbehaves.
    public var appVersion: String?
    /// When the file was written. Informational; JSON carries it as ISO 8601 so
    /// the header stays readable if anyone ever extracts one.
    public var savedAt: Date?
    public var image: ProjectImageInfo

    /// The digitising session: calibration, curves, and the sampling settings.
    ///
    /// The whole of it, rather than a field-by-field copy: `ProjectState` is
    /// already the complete description of everything but the image, so storing
    /// it whole is what stops the file format and the model from drifting apart
    /// the next time a setting is added.
    public var state: ProjectState

    public init(appVersion: String? = nil,
                savedAt: Date? = nil,
                image: ProjectImageInfo,
                state: ProjectState) {
        self.appVersion = appVersion
        self.savedAt = savedAt
        self.image = image
        self.state = state
    }
}

// MARK: - The document

/// A project as it exists in memory: the header plus the image it describes.
///
/// One value for the whole round trip, so the writer and the reader cannot
/// disagree about what a project contains — there is no second list of fields to
/// keep in step.
public struct ProjectDocument: Equatable, Sendable {

    public var header: ProjectHeader

    /// The source image, **byte for byte as it was read**.
    ///
    /// Not re-encoded. Decoding a PNG and encoding it again is not guaranteed to
    /// return the same pixels, and every extracted point is a pixel coordinate
    /// into that image: a shift of one bit anywhere would leave the calibration
    /// anchors and every curve sitting against a picture that no longer exists.
    /// Keeping the original bytes is also what makes the round trip provably
    /// lossless — the selftest compares the bytes, not a decoded approximation of
    /// them — and it costs nothing, because the bytes are what the user opened.
    public var imageData: Data

    public init(header: ProjectHeader, imageData: Data) {
        self.header = header
        self.imageData = imageData
    }
}

// MARK: - Errors

public enum ProjectFileError: Error, Equatable {
    /// The file does not begin with this format's magic number: it is some other
    /// kind of file, or not a file at all.
    case notAProjectFile
    /// Written by a newer format than this build understands.
    case unsupportedVersion(Int)
    /// The prologue promises a header longer than the file actually is.
    case truncatedHeader
    /// The header is present but is not the JSON this format expects.
    case malformedHeader
    /// The header decoded, but there are no image bytes behind it.
    case missingImage
}

extension ProjectFileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAProjectFile:
            return "这不是一个 GraphDigger 项目文件。"
        case .unsupportedVersion(let version):
            return "这个项目文件是更新版本的 GraphDigger 保存的(格式 v\(version)),"
                + "当前版本读不了。请升级 GraphDigger 后再打开。"
        case .truncatedHeader:
            return "项目文件不完整 —— 头部数据缺失,文件可能在传输或保存过程中被截断了。"
        case .malformedHeader:
            return "项目文件已损坏 —— 内部的描述数据无法解析。"
        case .missingImage:
            return "项目文件里没有图片数据,无法还原这张图表。"
        }
    }
}

// MARK: - The container

/// The project file format.
///
/// A single file, laid out so that the image is stored as-is and the structured
/// data can be parsed without touching it:
///
///     offset  length  contents
///     ------  ------  -----------------------------------------------------
///          0       8  magic — the bytes of "GDIGPRJ" plus a NUL
///          8       4  format version, unsigned 32-bit, little-endian
///         12       4  header length,  unsigned 32-bit, little-endian
///         16       N  header — UTF-8 JSON, `ProjectHeader`
///     16 + N   to end  image — the source file, byte for byte
///
/// ## Why a hand-rolled container and not a .zip
///
/// Zipping would work — it is the obvious shape for "some JSON and a PNG" — but
/// Foundation has no zip API, so it would mean either a third-party dependency in
/// a project that has none, or shelling out to `/usr/bin/zip`, which is a
/// process spawn and an error path that cannot be unit-tested. The layout above
/// gets the same property — structured data that can be read without decoding
/// the image — from sixteen bytes of prologue and two integer reads, and it
/// cannot be got wrong by a compressor.
///
/// ## Why not base64 in a JSON envelope
///
/// Because it inflates the image by a third for no gain. A chart scan is the
/// bulk of the file by two orders of magnitude, and base64 would also force a
/// decode-then-re-encode of every byte on both sides of the trip.
///
/// ## Compatibility
///
/// The version sits in the prologue rather than in the header so an unreadable
/// file is rejected before any parsing — a future format is free to change the
/// header's very shape. `currentVersion` is what this build writes; anything
/// greater is refused with a message that says so.
public enum ProjectFile {

    /// Eight bytes at the head of every project file. `"GDIGPRJ"` followed by a
    /// NUL: the padding is not decoration — a fixed length means the magic can
    /// never be a prefix of a longer string, and it makes the prologue a round
    /// sixteen bytes.
    public static let magic: [UInt8] = [0x47, 0x44, 0x49, 0x47, 0x50, 0x52, 0x4A, 0x00]

    /// The layout version this build writes. Raise it only for a change an older
    /// reader could not tolerate; adding a field to the header is not one of
    /// those, provided the field is optional — see `ProjectHeader`.
    public static let currentVersion = 1

    /// Magic (8) + version (4) + header length (4).
    public static let prologueLength = 16

    /// Extension the app registers and the save panel appends.
    public static let fileExtension = "gdproj"

    /// Uniform type identifier for `.gdproj`, declared in the app bundle's
    /// `Info.plist` so the Finder hands these files to this app on a
    /// double-click.
    public static let typeIdentifier = "com.example.graphdigger.project"
}

// MARK: - Reading and writing

extension ProjectDocument {

    /// The bytes to write to disk.
    ///
    /// Throws only if the header cannot be encoded, which for this model means a
    /// value that JSON cannot represent — a non-finite `Double` in a point, say.
    /// Reported rather than silently coerced: a NaN written out is a point no
    /// chart can plot, and the user is better told at save time than at open.
    public func serialized() throws -> Data {
        let encoder = JSONEncoder()
        // ISO 8601 rather than the default floating-point interval: a header that
        // can be read is worth the handful of bytes, and it removes any question
        // of which epoch a bare number meant.
        encoder.dateEncodingStrategy = .iso8601
        let headerData = try encoder.encode(header)

        var out = Data(capacity: ProjectFile.prologueLength + headerData.count + imageData.count)
        out.append(contentsOf: ProjectFile.magic)
        out.append(contentsOf: Self.uint32LE(UInt32(ProjectFile.currentVersion)))
        out.append(contentsOf: Self.uint32LE(UInt32(headerData.count)))
        out.append(headerData)
        out.append(imageData)
        return out
    }

    /// Reads a project back.
    ///
    /// Every failure is a distinct case rather than one "could not read", because
    /// the two the user can act on want opposite advice: a truncated file is
    /// worth looking for a copy of, and a newer-format file just needs a newer
    /// app.
    public init(serialized data: Data) throws {
        let prologue = ProjectFile.prologueLength
        guard data.count >= prologue else { throw ProjectFileError.notAProjectFile }

        // The prologue is read through a raw buffer rather than by indexing into
        // `data`. A `Data` taken as a slice of a larger buffer — which is what a
        // caller who hands over `whole.dropFirst(n)` produces, and what a
        // fixture or a stream decoder is likely to have — keeps its parent's
        // indices, so `data[12]` would read the wrong byte and the failure would
        // look like a corrupt file rather than a caller's slicing. A raw buffer
        // is zero-based relative to the bytes it actually covers, always.
        let (version, headerLength) = try data.withUnsafeBytes { raw -> (UInt32, UInt32) in
            for (offset, expected) in ProjectFile.magic.enumerated() where raw[offset] != expected {
                throw ProjectFileError.notAProjectFile
            }
            return (Self.uint32LE(raw, at: 8), Self.uint32LE(raw, at: 12))
        }

        guard version >= 1 else { throw ProjectFileError.notAProjectFile }
        guard version <= UInt32(ProjectFile.currentVersion) else {
            throw ProjectFileError.unsupportedVersion(Int(version))
        }

        let bodyOffset = prologue + Int(headerLength)
        // Checked against the file's actual length *before* a byte is read out of
        // it. The length comes from a file that may be corrupt, so it is treated
        // as a claim rather than a fact; everything past this guard may assume
        // the range it names exists.
        guard bodyOffset <= data.count else { throw ProjectFileError.truncatedHeader }

        var headerData = Data()
        headerData.append(contentsOf: data.dropFirst(prologue).prefix(Int(headerLength)))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header: ProjectHeader
        do {
            header = try decoder.decode(ProjectHeader.self, from: headerData)
        } catch {
            throw ProjectFileError.malformedHeader
        }

        // `append(contentsOf:)` rather than `Data(slice)`: it builds a fresh
        // zero-based buffer either way, and there is no question of which
        // initializer overload wins. This is the file's largest copy and it is
        // deliberate — what comes out is a standalone value that does not pin
        // the whole file in memory behind it.
        var imageData = Data()
        imageData.append(contentsOf: data.dropFirst(bodyOffset))

        // A project with no image is not a project: every stored point is a pixel
        // coordinate, and there is nothing to put them on.
        guard !imageData.isEmpty else { throw ProjectFileError.missingImage }

        self.init(header: header, imageData: imageData)
    }

    // MARK: - Integer helpers

    /// Little-endian, written a byte at a time.
    ///
    /// Spelled out rather than going through `withUnsafeBytes(of:)` so the byte
    /// order is stated in the source rather than inferred from the host: the
    /// format is little-endian, and reading it the other way would be a bug that
    /// only shows up on hardware nobody here has.
    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF),
         UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF),
         UInt8((value >> 24) & 0xFF)]
    }

    /// The same, read back. Takes a raw buffer for the reason given in
    /// `init(serialized:)`, and is only ever called once the magic has been
    /// checked, so the four bytes are known to be there.
    private static func uint32LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(raw[offset])
            | UInt32(raw[offset + 1]) << 8
            | UInt32(raw[offset + 2]) << 16
            | UInt32(raw[offset + 3]) << 24
    }
}
