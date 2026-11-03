// Photoshop brush (.abr) parser.
// Format reference: GIMP, app/core/gimpbrush-load.c and gimp_data_input_stream_rle_decode()
// in app/core/gimp-utils.c (GPLv3). Layouts below follow GIMP; deviations are commented.
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

public enum ABRError: Error, Equatable, CustomStringConvertible {
    case truncated
    case unsupportedVersion(Int, subversion: Int? = nil)
    case noSampleSection
    case corrupt(String)

    public var description: String {
        switch self {
        case .truncated: "The file is truncated."
        case let .unsupportedVersion(v, sub?): "Unsupported ABR version \(v) (subversion \(sub))"
        case let .unsupportedVersion(v, nil): "Unsupported ABR version \(v)"
        case .noSampleSection: "This file contains no bitmap brushes."
        case let .corrupt(why): "The file is damaged (\(why))."
        }
    }
}

/// One bitmap brush. Holds a slice of the (memory-mapped) file; pixels are decoded on demand.
public struct Brush: Sendable {
    public let width: Int
    public let height: Int
    let bytesPerSample: Int  // 1, or 2 for uncompressed 16-bit
    let rle: Bool
    let data: Data           // raw: pixels; RLE: int16 row lengths, then PackBits rows
}

public struct ABRFile: Sendable {
    public static let maxSide = 8192  // GIMP allows 10000; tighter for Quick Look's memory limits

    public let version: Int
    public private(set) var brushes: [Brush] = []
    /// Computed brushes and samples we can't render (other depths, oversize).
    public private(set) var skipped = 0
    /// Parsing stopped early on bad data; `brushes` holds everything before that point.
    public private(set) var isDamaged = false

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws(ABRError) {
        var r = Reader(data)
        version = try r.i16()
        let count = try r.i16()  // brush count for v1/v2, subversion for v6/v10
        switch version {
        case 1, 2:
            try readV12(&r, count: count)
        case 6, 10:
            guard count == 1 || count == 2 else { throw .unsupportedVersion(version, subversion: count) }
            try readV6(&r, subversion: count)
        default:
            throw .unsupportedVersion(version)
        }
    }

    private mutating func readV12(_ r: inout Reader, count: Int) throws(ABRError) {
        for _ in 0..<max(count, 0) {
            do throws(ABRError) {
                let type = try r.i16()
                let size = try r.i32()
                guard size >= 0 else { throw .corrupt("negative brush size") }
                let blockEnd = r.pos + size
                guard type == 2 else {  // 1 = computed, anything else unknown
                    skipped += 1
                    try r.seek(blockEnd)
                    continue
                }
                try r.skip(4 + 2)  // misc, spacing
                if version == 2 { try r.skip(2 * max(try r.i32(), 0)) }  // UCS-2 name, length in chars
                try r.skip(1 + 8)  // antialias, int16 bounds (superseded by the int32 ones)
                let top = try r.i32(), left = try r.i32(), bottom = try r.i32(), right = try r.i32()
                let depth = try r.i16()
                let compress = try r.u8()
                let w = right - left, h = bottom - top
                // GIMP aborts the whole file here; the block size lets us skip just this brush.
                guard depth == 8, Self.fits(w, h) else {
                    skipped += 1
                    try r.seek(blockEnd)
                    continue
                }
                brushes.append(try Self.sample(&r, w, h, bytesPerSample: 1, rle: compress != 0))
            } catch {
                try fail(error)
                return
            }
        }
    }

    private mutating func readV6(_ r: inout Reader, subversion: Int) throws(ABRError) {
        while true {  // walk "8BIM" sections until "samp"
            guard r.end - r.pos >= 8, try r.tag() == "8BIM" else { throw .noSampleSection }
            if try r.tag() == "samp" { break }
            let size = try r.i32()
            guard size >= 0 else { throw .corrupt("negative section size") }
            try r.skip(size)
        }
        let sectionSize = try r.i32()
        guard sectionSize >= 0 else { throw .corrupt("negative section size") }
        let sectionEnd = min(r.pos + sectionSize, r.end)

        while r.pos < sectionEnd {
            do throws(ABRError) {
                let size = try r.i32()
                guard size >= 0 else { throw .corrupt("negative brush size") }
                let next = r.pos + ((size + 3) & ~3)  // padded to 4
                try r.skip(subversion == 1 ? 47 : 301)  // key, short coordinates, unknown fields
                let top = try r.i32(), left = try r.i32(), bottom = try r.i32(), right = try r.i32()
                let bytes = try r.i16() >> 3
                let compress = try r.u8()
                let w = right - left, h = bottom - top
                let supported = (compress == 0 && (1...2).contains(bytes)) || (compress == 1 && bytes == 1)
                if supported && Self.fits(w, h) {
                    brushes.append(try Self.sample(&r, w, h, bytesPerSample: bytes, rle: compress == 1))
                } else {
                    skipped += 1
                }
                try r.seek(min(max(r.pos, next), r.end))
            } catch {
                try fail(error)
                return
            }
        }
    }

    /// Mid-file errors keep the brushes read so far; only an error before the first brush is fatal.
    private mutating func fail(_ error: ABRError) throws(ABRError) {
        guard !brushes.isEmpty else { throw error }
        isDamaged = true
    }

    private static func fits(_ w: Int, _ h: Int) -> Bool {
        (1...maxSide).contains(w) && (1...maxSide).contains(h)
    }

    /// Records where the sample's pixel data lives and skips past it; validates RLE row lengths.
    private static func sample(_ r: inout Reader, _ w: Int, _ h: Int, bytesPerSample: Int, rle: Bool) throws(ABRError) -> Brush {
        let start = r.pos
        if rle {
            var packed = 0
            for _ in 0..<h {
                let n = try r.i16()
                guard n > 0 else { throw .corrupt("bad RLE row length") }
                packed += n
            }
            try r.skip(packed)
        } else {
            try r.skip(w * h * bytesPerSample)
        }
        return Brush(width: w, height: h, bytesPerSample: bytesPerSample, rle: rle, data: r.data[start..<r.pos])
    }
}

/// Bounds-checked big-endian reader. `pos` is an absolute index into `data`.
struct Reader {
    let data: Data
    var pos: Int
    var end: Int { data.endIndex }

    init(_ data: Data) {
        self.data = data
        pos = data.startIndex
    }

    mutating func skip(_ n: Int) throws(ABRError) {
        guard n >= 0, n <= end - pos else { throw .truncated }
        pos += n
    }

    mutating func seek(_ target: Int) throws(ABRError) {
        guard (data.startIndex...end).contains(target) else { throw .truncated }
        pos = target
    }

    mutating func u8() throws(ABRError) -> UInt8 {
        try skip(1)
        return data[pos - 1]
    }

    mutating func i16() throws(ABRError) -> Int {
        try skip(2)
        return Int(Int16(bitPattern: UInt16(data[pos - 2]) << 8 | UInt16(data[pos - 1])))
    }

    mutating func i32() throws(ABRError) -> Int {
        try skip(4)
        let v = data[pos - 4..<pos].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Int(Int32(bitPattern: v))
    }

    mutating func tag() throws(ABRError) -> String {
        try skip(4)
        return String(decoding: data[pos - 4..<pos], as: UTF8.self)
    }
}

extension Brush {
    /// The brush as black ink whose alpha is the brush opacity, box-downsampled so neither
    /// side exceeds `maxPixelSize`. Decodes one row at a time, so memory scales with the
    /// output, not the brush. Returns nil if the pixel data is corrupt.
    public func image(maxPixelSize: Int) -> CGImage? {
        let scale = min(1, Double(max(maxPixelSize, 1)) / Double(max(width, height)))
        let ow = max(1, Int(Double(width) * scale)), oh = max(1, Int(Double(height) * scale))
        let column = (0..<width).map { $0 * ow / width }
        var columnCount = [Int](repeating: 0, count: ow)
        for c in column { columnCount[c] += 1 }

        var out = [UInt8](repeating: 0, count: ow * oh * 2)  // gray 0 + premultiplied alpha
        var sums = [Int](repeating: 0, count: ow)
        var row = [UInt8](repeating: 0, count: width)
        var band = 0, bandRows = 0
        func flush() {
            for x in 0..<ow {
                out[(band * ow + x) * 2 + 1] = UInt8(sums[x] / (columnCount[x] * bandRows))
                sums[x] = 0
            }
            bandRows = 0
        }

        var packed = data.startIndex + 2 * height  // RLE: start of the next packed row
        for y in 0..<height {
            if rle {
                let p = data.startIndex + 2 * y
                let n = Int(UInt16(data[p]) << 8 | UInt16(data[p + 1]))  // validated > 0 by the parser
                guard packed + n <= data.endIndex, Self.unpack(data[packed..<packed + n], into: &row) else { return nil }
                packed += n
            } else {
                let start = data.startIndex + y * width * bytesPerSample
                for x in 0..<width {
                    if bytesPerSample == 1 {
                        row[x] = data[start + x]
                    } else {
                        // GIMP reads 16-bit samples little-endian (GUINT16_FROM_LE)
                        let v = UInt32(data[start + 2 * x]) | UInt32(data[start + 2 * x + 1]) << 8
                        row[x] = UInt8(v * 255 / 65535)
                    }
                }
            }
            let oy = y * oh / height
            if oy != band { flush(); band = oy }
            for x in 0..<width { sums[column[x]] += Int(row[x]) }
            bandRows += 1
        }
        flush()

        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(
            width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 16, bytesPerRow: ow * 2,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// PackBits, as GIMP decodes it. Unlike GIMP (one continuous buffer), each row is decoded
    /// on its own: overrunning the row is an error, a short row is zero-padded.
    static func unpack(_ src: Data, into row: inout [UInt8]) -> Bool {
        var i = src.startIndex, o = 0
        while i < src.endIndex {
            let n = Int(Int8(bitPattern: src[i]))
            i += 1
            if n == -128 { continue }  // no-op
            let count = n < 0 ? 1 - n : n + 1
            let literal = n >= 0
            guard i + (literal ? count : 1) <= src.endIndex, o + count <= row.count else { return false }
            for k in 0..<count { row[o + k] = src[literal ? i + k : i] }
            i += literal ? count : 1
            o += count
        }
        for k in o..<row.count { row[k] = 0 }
        return true
    }
}
