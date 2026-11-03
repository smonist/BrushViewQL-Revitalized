// Generates Fixtures/sample.abr: a set of procedural brushes in ABR v2 format.
// Run from the repo root: swift Fixtures/make-sample.swift
//
// The brushes are drawn from math, not from any existing brush set, and both this script and
// its output are dedicated to the public domain (CC0 1.0).

import Foundation

struct Writer {
    var d = Data()
    mutating func u8(_ v: Int) { d.append(UInt8(truncatingIfNeeded: v)) }
    mutating func i16(_ v: Int) { u8(v >> 8); u8(v) }
    mutating func i32(_ v: Int) { i16(v >> 16); i16(v) }
}

/// Deterministic, so the file is byte-identical on every run.
struct Rng {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
}

func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
/// Antialiased coverage for a signed distance (negative = inside).
func inside(_ d: Double, soft: Double = 1.2) -> Double { clamp(0.5 - d / soft) }
func hash(_ x: Int, _ y: Int) -> Double {
    var h = UInt64(bitPattern: Int64(x &* 374761393 &+ y &* 668265263))
    h = (h ^ (h >> 13)) &* 1274126177
    return Double((h ^ (h >> 16)) & 0xFFFF) / 65535
}

struct Brush {
    let name: String, w: Int, h: Int, opacity: (Double, Double) -> Double  // pixel coords → 0...1
}

var rng = Rng(s: 2026)
let drops = (0..<80).map { _ -> (Double, Double, Double) in
    let a = rng.next() * 2 * .pi, r = pow(rng.next(), 1.6) * 150
    return (210 + cos(a) * r * 1.3, 160 + sin(a) * r, 2 + pow(rng.next(), 3) * 26)
}
let blades = (0..<9).map { i -> (x: Double, len: Double, bend: Double) in
    (30 + Double(i) * 20 + rng.next() * 8, 220 + rng.next() * 170, (rng.next() - 0.5) * 120)
}

let brushes = [
    Brush(name: "Soft Round", w: 256, h: 256) { x, y in
        let r = hypot(x - 128, y - 128) / 124
        return clamp(1 - r * r) * clamp(1 - r * r)
    },
    Brush(name: "Hard Round", w: 128, h: 128) { x, y in inside(hypot(x - 64, y - 64) - 60) },
    Brush(name: "Splatter", w: 420, h: 320) { x, y in
        drops.reduce(0) { max($0, inside(hypot(x - $1.0, y - $1.1) - $1.2)) }
    },
    Brush(name: "Star", w: 300, h: 300) { x, y in
        let a = atan2(y - 150, x - 150), d = hypot(x - 150, y - 150)
        return inside(d - (62 + 80 * pow(abs(cos(2.5 * a)), 4)))
    },
    Brush(name: "Grass", w: 220, h: 400) { x, y in
        blades.reduce(0) { v, b in
            let t = (400 - y) / b.len
            guard t >= 0, t <= 1 else { return v }
            return max(v, inside(abs(x - (b.x + b.bend * t * t)) - (7 * (1 - t) + 0.4)))
        }
    },
    Brush(name: "Chalk", w: 360, h: 220) { x, y in
        let band = clamp(1 - pow(abs(y - 110) / 80, 4) - pow(abs(x - 180) / 170, 8))
        let grain = hash(Int(x) / 2, Int(y) / 2) * 0.6 + hash(Int(x), Int(y)) * 0.4
        return grain > 0.4 ? band * grain : 0
    },
    Brush(name: "Ripple", w: 320, h: 320) { x, y in
        let d = hypot(x - 160, y - 160)
        return (0.5 + 0.5 * cos(d / 5)) * (1 - d / 160) * inside(d - 156, soft: 4)
    },
]

/// PackBits, row by row (the RLE flavour Photoshop uses for brush samples).
func packBits(_ row: ArraySlice<UInt8>) -> [UInt8] {
    var out: [UInt8] = [], i = row.startIndex
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

var file = Writer()
file.i16(2)  // version
file.i16(brushes.count)
for (index, brush) in brushes.enumerated() {
    let pixels = (0..<brush.w * brush.h).map { i in
        UInt8(clamp(brush.opacity(Double(i % brush.w) + 0.5, Double(i / brush.w) + 0.5)) * 255)
    }
    let rle = index % 2 == 0  // mix raw and RLE samples
    var b = Writer()
    b.i32(0)   // misc
    b.i16(25)  // spacing, percent
    let name = Array(brush.name.utf16) + [0]
    b.i32(name.count)
    name.forEach { b.i16(Int($0)) }
    b.u8(1)  // antialias
    [0, 0, brush.h, brush.w].forEach { b.i16($0) }  // top, left, bottom, right
    [0, 0, brush.h, brush.w].forEach { b.i32($0) }
    b.i16(8)  // depth
    b.u8(rle ? 1 : 0)
    if rle {
        let rows = (0..<brush.h).map { packBits(pixels[$0 * brush.w..<($0 + 1) * brush.w]) }
        rows.forEach { b.i16($0.count) }
        rows.forEach { b.d.append(contentsOf: $0) }
    } else {
        b.d.append(contentsOf: pixels)
    }
    file.i16(2)  // sampled brush
    file.i32(b.d.count)
    file.d.append(b.d)
}

let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("sample.abr")
try file.d.write(to: out)
print("Wrote \(brushes.count) brushes, \(file.d.count) bytes to \(out.path)")
