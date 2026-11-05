import Foundation
import simd

typealias V2 = SIMD2<Double>

/// Projective transform mapping the unit square (or any quad) to a quad.
struct Homography {
    var m: simd_double3x3

    static let identity = Homography(m: matrix_identity_double3x3)

    /// Maps (0,0)->q0, (1,0)->q1, (1,1)->q2, (0,1)->q3.
    static func squareToQuad(_ q: [V2]) -> Homography {
        let x0 = q[0].x, y0 = q[0].y, x1 = q[1].x, y1 = q[1].y
        let x2 = q[2].x, y2 = q[2].y, x3 = q[3].x, y3 = q[3].y
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        var a = x1 - x0, b = x3 - x0, c = x0
        var d = y1 - y0, e = y3 - y0, f = y0
        var g = 0.0, h = 0.0
        let det = dx1 * dy2 - dx2 * dy1
        if (abs(dx3) > 1e-12 || abs(dy3) > 1e-12) && abs(det) > 1e-12 {
            g = (dx3 * dy2 - dx2 * dy3) / det
            h = (dx1 * dy3 - dx3 * dy1) / det
            a = x1 - x0 + g * x1
            b = x3 - x0 + h * x3
            d = y1 - y0 + g * y1
            e = y3 - y0 + h * y3
        }
        _ = c; _ = f
        c = x0; f = y0
        return Homography(m: simd_double3x3(rows: [
            SIMD3(a, b, c), SIMD3(d, e, f), SIMD3(g, h, 1),
        ]))
    }

    static func quadToQuad(_ src: [V2], _ dst: [V2]) -> Homography {
        squareToQuad(dst) * squareToQuad(src).inverse
    }

    func apply(_ v: V2) -> V2 {
        let r = m * SIMD3(v.x, v.y, 1)
        let z = abs(r.z) < 1e-12 ? (r.z < 0 ? -1e-12 : 1e-12) : r.z
        return V2(r.x / z, r.y / z)
    }

    var inverse: Homography { Homography(m: m.inverse) }

    static func * (l: Homography, r: Homography) -> Homography { Homography(m: l.m * r.m) }
}

// MARK: - Grid warp

/// A continuous warp through a grid of points: one perspective transform through the
/// four outer corners, plus a bilinearly interpolated correction that makes it pass
/// exactly through every inner point. With a single cell it is pure perspective.
/// (Separate per-cell homographies would disagree along shared edges and tear lines.)
struct GridWarp {
    let cols: Int
    let rows: Int
    let h: Homography
    let res: [V2]

    init(cols: Int, rows: Int, points: [V2]) {
        self.cols = cols; self.rows = rows
        let w = cols + 1
        let hh = Homography.squareToQuad([points[0], points[cols], points[rows * w + cols], points[rows * w]])
        h = hh
        var r: [V2] = []
        r.reserveCapacity(points.count)
        for j in 0...rows {
            for i in 0...cols {
                r.append(points[j * w + i] - hh.apply(V2(Double(i) / Double(cols), Double(j) / Double(rows))))
            }
        }
        res = r
    }

    /// Grid coordinates (0...1 across the grid) to output. Outside the grid the
    /// perspective part extrapolates and the correction holds its edge value.
    func apply(_ st: V2) -> V2 {
        let base = h.apply(st)
        if cols == 1 && rows == 1 { return base }
        let u = min(max(st.x, 0), 1) * Double(cols), v = min(max(st.y, 0), 1) * Double(rows)
        let i = min(Int(u), cols - 1), j = min(Int(v), rows - 1)
        let fu = u - Double(i), fv = v - Double(j)
        let w = cols + 1
        let r = res[j * w + i] * ((1 - fu) * (1 - fv)) + res[j * w + i + 1] * (fu * (1 - fv))
            + res[(j + 1) * w + i] * ((1 - fu) * fv) + res[(j + 1) * w + i + 1] * (fu * fv)
        return base + r
    }
}

// MARK: - Surface geometry

extension Surface {
    func p(_ i: Int, _ j: Int) -> V2 { points[j * (cols + 1) + i] }

    var warp: GridWarp { GridWarp(cols: cols, rows: rows, points: points) }

    /// Position on the output for surface coordinates (s,t) in 0...1.
    func eval(_ s: Double, _ t: Double) -> V2 {
        warp.apply(V2(min(max(s, 0), 1), min(max(t, 0), 1)))
    }

    /// The true (possibly curved) edge, sampled along the warp. Closed: last point equals first.
    func outline(samplesPerCell: Int = 8) -> [V2] {
        let w = warp
        let ns = cols * rows == 1 ? 1 : cols * samplesPerCell, nt = cols * rows == 1 ? 1 : rows * samplesPerCell
        var st: [V2] = []
        for a in 0..<ns { st.append(V2(Double(a) / Double(ns), 0)) }
        for b in 0..<nt { st.append(V2(1, Double(b) / Double(nt))) }
        for a in stride(from: ns, to: 0, by: -1) { st.append(V2(Double(a) / Double(ns), 1)) }
        for b in stride(from: nt, to: 0, by: -1) { st.append(V2(0, Double(b) / Double(nt))) }
        st.append(V2(0, 0))
        return st.map(w.apply)
    }

    /// Closed outline, walking the edge grid points clockwise from the top-left.
    var boundary: [V2] {
        var b: [V2] = []
        for i in 0...cols { b.append(p(i, 0)) }
        if rows > 0 { for j in 1...rows { b.append(p(cols, j)) } }
        for i in stride(from: cols - 1, through: 0, by: -1) { b.append(p(i, rows)) }
        if rows > 1 { for j in stride(from: rows - 1, through: 1, by: -1) { b.append(p(0, j)) } }
        return b
    }

    var cornerIndices: [Int] {
        [0, cols, (rows + 1) * (cols + 1) - 1, rows * (cols + 1)]
    }

    var corners: [V2] { cornerIndices.map { points[$0] } }

    func contains(_ q: V2) -> Bool { pointInPolygon(q, outline(samplesPerCell: 4)) }

    static func gridPoints(corners: [V2], cols: Int, rows: Int) -> [V2] {
        let h = Homography.squareToQuad(corners)
        var pts: [V2] = []
        for j in 0...rows {
            for i in 0...cols { pts.append(h.apply(V2(Double(i) / Double(cols), Double(j) / Double(rows)))) }
        }
        return pts
    }

    /// Change the bend grid density while keeping the current shape.
    mutating func resample(cols nc: Int, rows nr: Int) {
        let nc = max(1, min(nc, 12)), nr = max(1, min(nr, 12))
        guard nc != cols || nr != rows else { return }
        var pts: [V2] = []
        for j in 0...nr {
            for i in 0...nc { pts.append(eval(Double(i) / Double(nc), Double(j) / Double(nr))) }
        }
        points = pts; cols = nc; rows = nr
    }

    /// Flatten the bend grid back onto the plane of the four corners.
    mutating func flatten() {
        points = Surface.gridPoints(corners: corners, cols: cols, rows: rows)
    }
}

func pointInPolygon(_ p: V2, _ poly: [V2]) -> Bool {
    guard poly.count >= 3 else { return false }
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i], b = poly[j]
        if (a.y > p.y) != (b.y > p.y) {
            let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
            if p.x < x { inside.toggle() }
        }
        j = i
    }
    return inside
}

func distanceToSegment(_ p: V2, _ a: V2, _ b: V2) -> Double {
    let ab = b - a
    let l2 = simd_length_squared(ab)
    if l2 < 1e-18 { return simd_length(p - a) }
    let t = max(0, min(1, simd_dot(p - a, ab) / l2))
    return simd_length(p - (a + ab * t))
}

/// Ear-clipping triangulation of a simple polygon. Returns index triples.
func triangulate(_ pts: [V2]) -> [Int] {
    let n = pts.count
    guard n >= 3 else { return [] }
    var area = 0.0
    for i in 0..<n {
        let a = pts[i], b = pts[(i + 1) % n]
        area += a.x * b.y - b.x * a.y
    }
    var idx = Array(0..<n)
    if area < 0 { idx.reverse() }
    func cross(_ a: V2, _ b: V2, _ c: V2) -> Double {
        let u = b - a, v = c - b
        return u.x * v.y - u.y * v.x
    }
    func inTri(_ p: V2, _ a: V2, _ b: V2, _ c: V2) -> Bool {
        cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0
    }
    var out: [Int] = []
    var guardCount = 0
    while idx.count > 3 && guardCount < 10_000 {
        guardCount += 1
        let m = idx.count
        var clipped = false
        for k in 0..<m {
            let i0 = idx[(k + m - 1) % m], i1 = idx[k], i2 = idx[(k + 1) % m]
            let a = pts[i0], b = pts[i1], c = pts[i2]
            if cross(a, b, c) <= 1e-14 { continue }
            var ok = true
            for o in idx where o != i0 && o != i1 && o != i2 {
                if inTri(pts[o], a, b, c) { ok = false; break }
            }
            if ok {
                out += [i0, i1, i2]
                idx.remove(at: k)
                clipped = true
                break
            }
        }
        if !clipped { break }
    }
    if idx.count == 3 {
        out += idx
    } else if idx.count > 3 {
        // Self-intersecting leftovers: fan them so the mask still covers something.
        for k in 1..<(idx.count - 1) { out += [idx[0], idx[k], idx[k + 1]] }
    }
    return out
}

// MARK: - Colour geometry batches

typealias RGBA = SIMD4<Float>

enum Palette {
    static let corner: [RGBA] = [
        RGBA(1, 0.25, 0.25, 1), RGBA(0.25, 1, 0.35, 1), RGBA(0.3, 0.55, 1, 1), RGBA(1, 0.9, 0.2, 1),
    ]
    static let white = RGBA(1, 1, 1, 1)
    static let black = RGBA(0, 0, 0, 1)
    static let accent = RGBA(0.2, 0.85, 1, 1)
    static let mask = RGBA(1, 0.3, 0.85, 1)
    static let dim = RGBA(1, 1, 1, 0.45)
    static let calibColors: [RGBA] = corner + [
        RGBA(1, 0.35, 1, 1), RGBA(0.3, 1, 1, 1), RGBA(1, 0.6, 0.2, 1), RGBA(0.7, 0.5, 1, 1),
    ]
    static func calib(_ k: Int) -> RGBA { calibColors[k % calibColors.count] }
}

/// Accumulates coloured triangles in normalized space. `unit` is the size of one
/// pixel (or point) in normalized units, so widths and radii are given in pixels.
struct ColorBatch {
    var v: [Float] = []
    var unit: V2

    init(unit: V2) { self.unit = unit }

    var isEmpty: Bool { v.isEmpty }
    var vertexCount: Int { v.count / 6 }

    mutating func tri(_ a: V2, _ b: V2, _ c: V2, _ col: RGBA) {
        for p in [a, b, c] { v += [Float(p.x), Float(p.y), col.x, col.y, col.z, col.w] }
    }

    mutating func quad(_ a: V2, _ b: V2, _ c: V2, _ d: V2, _ col: RGBA) {
        tri(a, b, c, col); tri(a, c, d, col)
    }

    mutating func line(_ a: V2, _ b: V2, _ w: Double, _ col: RGBA, caps: Bool = true) {
        let d = V2((b.x - a.x) / unit.x, (b.y - a.y) / unit.y)
        let len = simd_length(d)
        guard len > 1e-9, len.isFinite else { return }
        let dir = d / len
        let n = V2(-dir.y, dir.x) * (w / 2)
        let t = caps ? dir * (w / 2) : V2(0, 0)
        let nn = V2(n.x * unit.x, n.y * unit.y), tt = V2(t.x * unit.x, t.y * unit.y)
        let a2 = a - tt, b2 = b + tt
        quad(a2 + nn, b2 + nn, b2 - nn, a2 - nn, col)
    }

    mutating func polyline(_ pts: [V2], closed: Bool, _ w: Double, _ col: RGBA) {
        guard pts.count >= 2 else { return }
        for i in 0..<(pts.count - 1) { line(pts[i], pts[i + 1], w, col) }
        if closed { line(pts[pts.count - 1], pts[0], w, col) }
    }

    mutating func disc(_ c: V2, _ r: Double, _ col: RGBA, segments: Int = 20) {
        var prev = c + V2(r * unit.x, 0)
        for k in 1...segments {
            let a = Double(k) / Double(segments) * 2 * .pi
            let p = c + V2(cos(a) * r * unit.x, sin(a) * r * unit.y)
            tri(c, prev, p, col)
            prev = p
        }
    }

    mutating func ring(_ c: V2, _ r: Double, _ w: Double, _ col: RGBA, segments: Int = 28) {
        for k in 0..<segments {
            let a0 = Double(k) / Double(segments) * 2 * .pi
            let a1 = Double(k + 1) / Double(segments) * 2 * .pi
            let o0 = V2(cos(a0), sin(a0)), o1 = V2(cos(a1), sin(a1))
            func at(_ o: V2, _ rr: Double) -> V2 { c + V2(o.x * rr * unit.x, o.y * rr * unit.y) }
            quad(at(o0, r - w / 2), at(o0, r + w / 2), at(o1, r + w / 2), at(o1, r - w / 2), col)
        }
    }

    mutating func handle(_ c: V2, _ r: Double, _ col: RGBA) {
        disc(c, r + 1.5, RGBA(0, 0, 0, 0.8))
        disc(c, r, col)
    }
}
