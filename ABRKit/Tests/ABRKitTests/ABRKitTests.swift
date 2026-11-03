import CoreGraphics
import Foundation
import Testing
@testable import ABRKit

// MARK: - Test-only ABR writer (mirrors the layouts parsed in ABR.swift)

struct Writer {
    var d = Data()
    mutating func u8(_ v: Int) { d.append(UInt8(truncatingIfNeeded: v)) }
    mutating func i16(_ v: Int) { u8(v >> 8); u8(v) }
    mutating func i32(_ v: Int) { i16(v >> 16); i16(v) }
    mutating func raw<S: Sequence>(_ b: S) where S.Element == UInt8 { d.append(contentsOf: b) }
}

struct Sample {
    let w: Int, h: Int, pixels: [UInt8]

    /// Left half varies per pixel (literals), right half is constant per row (runs).
    init(_ w: Int, _ h: Int) {
        self.w = w
        self.h = h
        pixels = (0..<w * h).map { i in
            let x = i % w, y = i / w
            return UInt8(truncatingIfNeeded: x < w / 2 ? x * 7 + y : y * 40)
        }
    }
}

/// PackBits with a leading no-op byte per row, to exercise the -128 case.
func packBits(_ row: ArraySlice<UInt8>) -> [UInt8] {
    var out: [UInt8] = [0x80], i = row.startIndex
    while i < row.endIndex {
        var run = 1
        while i + run < row.endIndex, run < 128, row[i + run] == row[i] { run += 1 }
        if run >= 2 {
            out += [UInt8(bitPattern: Int8(1 - run)), row[i]]
            i += run
        } else {
            var j = i + 1
            while j < row.endIndex, j - i < 128, !(j + 1 < row.endIndex && row[j] == row[j + 1]) { j += 1 }
            out += [UInt8(j - i - 1)] + row[i..<j]
            i = j
        }
    }
    return out
}

func pixelData(_ s: Sample, rle: Bool) -> [UInt8] {
    guard rle else { return s.pixels }
    let rows = (0..<s.h).map { packBits(s.pixels[$0 * s.w..<($0 + 1) * s.w]) }
    var w = Writer()
    rows.forEach { w.i16($0.count) }
    rows.forEach { w.raw($0) }
    return Array(w.d)
}

/// v1/v2 file: one computed brush (skipped), then the samples.
func abrV12(version: Int, _ samples: [Sample], rle: Bool) -> Data {
    var w = Writer()
    w.i16(version)
    w.i16(samples.count + 1)
    w.i16(1); w.i32(14); w.raw([UInt8](repeating: 0, count: 14))
    for s in samples {
        var b = Writer()
        b.i32(0); b.i16(25)
        if version == 2 {
            let name = Array("brush".utf16) + [0]
            b.i32(name.count)
            name.forEach { b.i16(Int($0)) }
        }
        b.u8(1)
        [0, 0, s.h, s.w].forEach { b.i16($0) }
        [0, 0, s.h, s.w].forEach { b.i32($0) }
        b.i16(8); b.u8(rle ? 1 : 0)
        b.raw(pixelData(s, rle: rle))
        w.i16(2); w.i32(b.d.count); w.d.append(b.d)
    }
    return w.d
}

/// v6 file: a "desc" section before "samp" and a "patt" after, both skipped.
func abrV6(subversion: Int, _ samples: [Sample], rle: Bool, depth16: Bool = false) -> Data {
    var samp = Writer()
    for s in samples {
        var b = Writer()
        b.raw([UInt8](repeating: 0x41, count: subversion == 1 ? 47 : 301))
        [0, 0, s.h, s.w].forEach { b.i32($0) }
        b.i16(depth16 ? 16 : 8); b.u8(rle ? 1 : 0)
        if depth16 {
            s.pixels.forEach { let v = Int($0) * 257; b.u8(v); b.u8(v >> 8) }  // little-endian, as GIMP reads it
        } else {
            b.raw(pixelData(s, rle: rle))
        }
        samp.i32(b.d.count); samp.d.append(b.d)
        while samp.d.count % 4 != 0 { samp.u8(0) }
    }
    var w = Writer()
    w.i16(6); w.i16(subversion)
    w.raw("8BIMdesc".utf8); w.i32(3); w.raw([1, 2, 3])
    w.raw("8BIMsamp".utf8); w.i32(samp.d.count); w.d.append(samp.d)
    w.raw("8BIMpatt".utf8); w.i32(0)
    return w.d
}

/// Alpha channel of an image produced by `Brush.image`.
func alpha(_ image: CGImage) -> [UInt8] {
    guard let data = image.dataProvider?.data as Data? else { return [] }
    return stride(from: 1, to: data.count, by: 2).map { data[$0] }
}

let samples = [Sample(13, 7), Sample(40, 3)]

func assertRoundTrip(_ data: Data) throws {
    let file = try ABRFile(data: data)
    #expect(!file.isDamaged)
    #expect(file.brushes.count == samples.count)
    for (brush, s) in zip(file.brushes, samples) {
        #expect((brush.width, brush.height) == (s.w, s.h))
        let image = try #require(brush.image(maxPixelSize: 9999))
        #expect(alpha(image) == s.pixels)
    }
}

// MARK: - Round trips

@Test(arguments: [1, 2], [false, true])
func roundTripV12(version: Int, rle: Bool) throws {
    try assertRoundTrip(abrV12(version: version, samples, rle: rle))
    #expect(try ABRFile(data: abrV12(version: version, samples, rle: rle)).skipped == 1)
}

@Test(arguments: [1, 2], [false, true])
func roundTripV6(subversion: Int, rle: Bool) throws {
    try assertRoundTrip(abrV6(subversion: subversion, samples, rle: rle))
}

@Test func sixteenBitDownconverts() throws {
    try assertRoundTrip(abrV6(subversion: 2, samples, rle: false, depth16: true))
}

@Test func downsamplesWithinLimit() throws {
    let file = try ABRFile(data: abrV6(subversion: 1, [Sample(300, 120)], rle: true))
    let image = try #require(file.brushes.first?.image(maxPixelSize: 64))
    #expect((image.width, image.height) == (64, 25))
}

// MARK: - Bad input

@Test func unsupportedVersions() {
    #expect(throws: ABRError.unsupportedVersion(3)) { try ABRFile(data: Data([0, 3, 0, 1])) }
    #expect(throws: ABRError.unsupportedVersion(6, subversion: 3)) { try ABRFile(data: Data([0, 6, 0, 3])) }
    #expect(throws: ABRError.truncated) { try ABRFile(data: Data([0])) }
    #expect(ABRError.unsupportedVersion(5).description == "Unsupported ABR version 5")
}

@Test func unsupportedSamplesAreSkipped() throws {
    var data = abrV6(subversion: 1, samples, rle: true)
    // header, desc section, samp header, sample size, header skip, bounds → first sample's depth
    let depthOffset = 4 + (8 + 4 + 3) + (8 + 4) + 4 + 47 + 16
    data[depthOffset + 1] = 32
    let file = try ABRFile(data: data)
    #expect(file.brushes.count == 1 && file.skipped == 1)
}

/// Every truncation and every single-byte corruption must parse or throw, never trap,
/// and decoding whatever parsed must not trap either.
@Test(arguments: [abrV12(version: 2, samples, rle: true), abrV6(subversion: 2, samples, rle: true)])
func malformedInputFailsGracefully(data: Data) {
    func exercise(_ d: Data) {
        guard let file = try? ABRFile(data: d) else { return }
        for b in file.brushes { _ = b.image(maxPixelSize: 32) }
    }
    for n in 0..<data.count { exercise(data.prefix(n)) }
    for i in 0..<data.count {
        for v: UInt8 in [0x00, 0x7F, 0x80, 0xFF] {
            var d = data
            d[i] = v
            exercise(d)
        }
    }
}

@Test func truncationKeepsEarlierBrushes() throws {
    let data = abrV6(subversion: 1, samples, rle: false)
    let file = try ABRFile(data: data.prefix(data.count - 30))
    #expect(file.isDamaged && file.brushes.count == 1)
}

// MARK: - Real files dropped into Fixtures/

let fixtures = (try? FileManager.default.contentsOfDirectory(
    at: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../Fixtures").standardized,
    includingPropertiesForKeys: nil
))?.filter { $0.pathExtension.lowercased() == "abr" } ?? []

@Test(arguments: fixtures)
func realFixture(url: URL) throws {
    let file = try ABRFile(contentsOf: url)
    #expect(!file.brushes.isEmpty)
    #expect(!file.isDamaged)
    for b in file.brushes {
        #expect((1...ABRFile.maxSide).contains(b.width) && (1...ABRFile.maxSide).contains(b.height))
    }
    #expect(file.brushes.allSatisfy { $0.image(maxPixelSize: 64) != nil })

    let data = try Data(contentsOf: url)
    for n in [3, 50, 400, data.count / 2, data.count - 1] where n < data.count {
        if let partial = try? ABRFile(data: data.prefix(n)) {
            for b in partial.brushes { _ = b.image(maxPixelSize: 32) }
        }
    }
}
