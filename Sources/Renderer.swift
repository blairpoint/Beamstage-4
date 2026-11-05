import Foundation
import Metal
import QuartzCore
import Syphon
import simd

struct Xf {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
    /// Normalized (0...1, y down) to clip space for a whole render target.
    static let full = Xf(scale: SIMD2(2, -2), offset: SIMD2(-1, 1))
}

struct TexUniforms {
    var opacity: Float = 1
    var feather: Float = 0
    var brightness: Float = 1
    var pad: Float = 0
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Xf { float2 scale; float2 offset; };
struct TexV { packed_float2 pos; packed_float2 uv; packed_float2 st; };
struct TexO { float4 position [[position]]; float2 uv; float2 st; };
struct TexU { float opacity; float feather; float brightness; float pad; };

vertex TexO texVert(uint vid [[vertex_id]], const device TexV* v [[buffer(0)]], constant Xf& xf [[buffer(1)]]) {
    TexO o;
    float2 p = float2(v[vid].pos);
    o.position = float4(p * xf.scale + xf.offset, 0, 1);
    o.uv = float2(v[vid].uv);
    o.st = float2(v[vid].st);
    return o;
}

fragment float4 texFrag(TexO in [[stage_in]], texture2d<float> t [[texture(0)]], constant TexU& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = t.sample(s, in.uv);
    float f = 1.0;
    if (u.feather > 0.0) {
        float2 e = min(in.st, 1.0 - in.st);
        f = smoothstep(0.0, u.feather, min(e.x, e.y));
    }
    float a = u.opacity * f;
    return float4(c.rgb * u.brightness, c.a) * a;   // texture is premultiplied
}

struct ColV { packed_float2 pos; packed_float4 col; };
struct ColO { float4 position [[position]]; float4 col; };

vertex ColO colVert(uint vid [[vertex_id]], const device ColV* v [[buffer(0)]], constant Xf& xf [[buffer(1)]]) {
    ColO o;
    float2 p = float2(v[vid].pos);
    o.position = float4(p * xf.scale + xf.offset, 0, 1);
    o.col = float4(v[vid].col);
    return o;
}

fragment float4 colFrag(ColO in [[stage_in]]) {
    return float4(in.col.rgb * in.col.a, in.col.a);
}
"""

enum SceneKind { case projector, laser }

/// Calibration and test overlays for one frame.
struct TestState {
    var test: LaserTest = .off
    var active: Int?
    /// False on the "off" half of a blink, so the laser can be told apart from the projection.
    var projectorVisible = true
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MediaLibrary
    private let texPipe: MTLRenderPipelineState
    private let colPipe: MTLRenderPipelineState
    private let white: MTLTexture

    private(set) var comp: MTLTexture?
    private(set) var laserTex: MTLTexture?
    private(set) var outputServer: SyphonMetalServer?
    private(set) var laserServer: SyphonMetalServer?
    private var lastLaserPublish: CFTimeInterval = 0

    init?(device: MTLDevice, library: MediaLibrary, syphon: Bool = true) {
        self.device = device
        self.library = library
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            texPipe = try Renderer.pipeline(device, lib, "texVert", "texFrag")
            colPipe = try Renderer.pipeline(device, lib, "colVert", "colFrag")
        } catch {
            NSLog("Beamstage: shader build failed: \(error)")
            return nil
        }
        guard let w = MediaLibrary.makeSolid(device: device) else { return nil }
        white = w
        if syphon {
            outputServer = SyphonMetalServer(name: "Beamstage Output", device: device, options: nil)
            laserServer = SyphonMetalServer(name: "Beamstage Laser", device: device, options: nil)
        }
    }

    private static func pipeline(_ device: MTLDevice, _ lib: MTLLibrary, _ v: String, _ f: String) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: v)
        d.fragmentFunction = lib.makeFunction(name: f)
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: d)
    }

    func makeTarget(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(16, width), height: max(16, height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func ensure(_ t: inout MTLTexture?, _ w: Int, _ h: Int) {
        let w = max(16, min(w, 8192)), h = max(16, min(h, 8192))
        if t == nil || t!.width != w || t!.height != h { t = makeTarget(width: w, height: h) }
    }

    // MARK: Frame

    struct FrameState {
        var project: Project
        var selectedSurface: UUID?
        var projectorBlackout: Bool
        var laserBlackout: Bool
        var needLaserPreview: Bool
        var test = TestState()
    }

    /// Renders the projector composite and the laser feed, and publishes both over Syphon.
    func renderFrame(_ s: FrameState, now: CFTimeInterval) {
        guard let cb = queue.makeCommandBuffer() else { return }
        ensure(&comp, s.project.outputWidth, s.project.outputHeight)
        guard let comp else { return }
        encodeScene(cb, target: comp, project: s.project, kind: .projector, selected: s.selectedSurface, blackout: s.projectorBlackout, test: s.test)
        if let srv = outputServer, srv.hasClients {
            srv.publishFrameTexture(comp, on: cb, imageRegion: NSRect(x: 0, y: 0, width: comp.width, height: comp.height), flipped: false)
        }

        let laserClients = laserServer?.hasClients ?? false
        let interval = 1.0 / Double(max(1, s.project.laser.fps))
        let due = now - lastLaserPublish >= interval - 0.004
        if (laserClients && due) || s.needLaserPreview {
            ensure(&laserTex, s.project.laser.width, s.project.laser.height)
            if let lt = laserTex {
                encodeScene(cb, target: lt, project: s.project, kind: .laser, selected: s.selectedSurface, blackout: s.laserBlackout, test: s.test)
                if laserClients && due, let srv = laserServer {
                    srv.publishFrameTexture(lt, on: cb, imageRegion: NSRect(x: 0, y: 0, width: lt.width, height: lt.height), flipped: false)
                    lastLaserPublish = now
                }
            }
        }
        cb.commit()
    }

    /// Sends a black laser frame and stops the servers (used on quit).
    func shutdown(project: Project) {
        if let cb = queue.makeCommandBuffer() {
            var t: MTLTexture? = laserTex
            ensure(&t, project.laser.width, project.laser.height)
            if let t {
                encodeScene(cb, target: t, project: project, kind: .laser, selected: nil, blackout: true)
                laserServer?.publishFrameTexture(t, on: cb, imageRegion: NSRect(x: 0, y: 0, width: t.width, height: t.height), flipped: false)
            }
            cb.commit(); cb.waitUntilCompleted()
        }
        laserServer?.stop(); outputServer?.stop()
        laserServer = nil; outputServer = nil
    }

    // MARK: Scene

    func encodeScene(_ cb: MTLCommandBuffer, target: MTLTexture, project: Project, kind: SceneKind, selected: UUID?, blackout: Bool,
                     test: TestState = TestState()) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        defer { enc.endEncoding() }
        if blackout { return }

        let unit = V2(1 / Double(target.width), 1 / Double(target.height))
        let visible = project.surfaces.filter(\.visible)

        switch kind {
        case .projector:
            let id: (V2) -> V2 = { $0 }
            for s in visible { drawSurface(enc, s, transform: id, texture: library.texture(s.mediaID), xf: .full) }
            drawMasks(enc, project.masks, transform: id, unit: unit, xf: .full)
            var b = ColorBatch(unit: unit)
            let showCrosses = test.test == .calibrate || (test.test == .off && project.laser.mode == .align)
            if showCrosses && test.projectorVisible {
                alignCrosses(&b, project: project, transform: id, width: 5, active: test.test == .calibrate ? test.active : nil)
            }
            if test.projectorVisible {
                // Draw what the laser is being sent, in cyan, so any offset shows.
                if test.test == .outlines {
                    for s in visible where s.toLaser { b.polyline(s.outline(), closed: false, 3, Palette.accent) }
                } else if test.test == .grid {
                    testGrid(&b, project: project, transform: id, width: 3, color: Palette.accent)
                }
            }
            drawBatch(enc, b, xf: .full)

        case .laser:
            let T = project.laser.makeTransform()
            let laserSurfaces = visible.filter(\.toLaser)
            let w = project.laser.lineWidth
            if test.test != .off {
                var b = ColorBatch(unit: unit)
                switch test.test {
                case .calibrate: alignCrosses(&b, project: project, transform: T, width: max(2, w), active: test.active)
                case .outlines: for s in laserSurfaces { b.polyline(densify(s.outline(), closed: false).map(T), closed: false, w, Palette.white) }
                case .grid: testGrid(&b, project: project, transform: T, width: w, color: Palette.white)
                case .off: break
                }
                drawBatch(enc, b, xf: .full)
                return
            }
            switch project.laser.mode {
            case .projection:
                for s in visible { drawSurface(enc, s, transform: T, texture: library.texture(s.mediaID), xf: .full) }
                drawMasks(enc, project.masks, transform: T, unit: unit, xf: .full)
            case .selected:
                if let s = visible.first(where: { $0.id == selected }) {
                    drawSurface(enc, s, transform: T, texture: library.texture(s.mediaID), xf: .full)
                }
                drawMasks(enc, project.masks, transform: T, unit: unit, xf: .full)
            case .silhouettes:
                for s in laserSurfaces {
                    var plain = s; plain.opacity = 1; plain.feather = 0; plain.brightness = 1
                    drawSurface(enc, plain, transform: T, texture: white, xf: .full)
                }
                drawMasks(enc, project.masks, transform: T, unit: unit, xf: .full)
            case .outlines:
                var b = ColorBatch(unit: unit)
                for s in laserSurfaces {
                    b.polyline(densify(s.outline(), closed: false).map(T), closed: false, w, Palette.white)
                }
                drawBatch(enc, b, xf: .full)
                drawMasks(enc, project.masks, transform: T, unit: unit, xf: .full)
            case .align:
                var b = ColorBatch(unit: unit)
                alignCrosses(&b, project: project, transform: T, width: max(2, w), active: nil)
                drawBatch(enc, b, xf: .full)
            }
        }
    }

    /// Splits long segments so they follow the calibration when it bends between points.
    func densify(_ pts: [V2], closed: Bool, maxStep: Double = 0.01) -> [V2] {
        guard pts.count >= 2 else { return pts }
        var out: [V2] = []
        let n = closed ? pts.count : pts.count - 1
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            let k = max(1, Int(ceil(simd_length(b - a) / maxStep)))
            for t in 0..<k { out.append(a + (b - a) * (Double(t) / Double(k))) }
        }
        out.append(closed ? pts[0] : pts[pts.count - 1])
        return out
    }

    /// Projector-space position of calibration point k (accounting for flips).
    static func projectorTarget(_ laser: LaserSettings, _ k: Int) -> V2 {
        var t = laser.calibration.targets[k]
        if laser.flipX { t.x = 1 - t.x }
        if laser.flipY { t.y = 1 - t.y }
        return t
    }

    /// A cross on every calibration point. Under the laser transform each cross lands on
    /// that point's handle, in the same colour as on the projector.
    func alignCrosses(_ b: inout ColorBatch, project: Project, transform T: (V2) -> V2, width: Double, active: Int?) {
        let aspect = Double(project.outputWidth) / Double(max(1, project.outputHeight))
        let cal = project.laser.calibration
        let sy = min(0.07, 0.3 / Double(max(cal.cols, cal.rows) + 1)), sx = sy / aspect
        for k in 0..<cal.count {
            let c = Renderer.projectorTarget(project.laser, k)
            let col = Palette.calib(k)
            let dim = active != nil && active != k
            let lw = dim ? max(1, width * 0.5) : width
            let colr = dim ? col * RGBA(1, 1, 1, 0.45) : col
            b.polyline(densify([c - V2(sx, 0), c + V2(sx, 0)], closed: false).map(T), closed: false, lw, colr)
            b.polyline(densify([c - V2(0, sy), c + V2(0, sy)], closed: false).map(T), closed: false, lw, colr)
            if active == k {
                // A circle marks the point being calibrated.
                let r = V2(sx * 0.6, sy * 0.6)
                let ring = (0...48).map { i -> V2 in
                    let a = Double(i) / 48 * 2 * .pi
                    return c + V2(cos(a) * r.x, sin(a) * r.y)
                }
                b.polyline(ring.map(T), closed: false, width, col)
            }
        }
    }

    /// Frame, grid and circle covering the calibrated area, for checking the whole picture.
    func testGrid(_ b: inout ColorBatch, project: Project, transform T: (V2) -> V2, width: Double, color: RGBA) {
        let lo = LaserCalibration.inset, hi = 1 - LaserCalibration.inset, n = 4
        for k in 0...n {
            let f = lo + (hi - lo) * Double(k) / Double(n)
            b.polyline(densify([V2(f, lo), V2(f, hi)], closed: false).map(T), closed: false, width, color)
            b.polyline(densify([V2(lo, f), V2(hi, f)], closed: false).map(T), closed: false, width, color)
        }
        let aspect = Double(project.outputWidth) / Double(max(1, project.outputHeight))
        let ry = (hi - lo) * 0.3, rx = ry / aspect
        let circle = (0...96).map { i -> V2 in
            let a = Double(i) / 96 * 2 * .pi
            return V2(0.5 + cos(a) * rx, 0.5 + sin(a) * ry)
        }
        b.polyline(circle.map(T), closed: false, width, color)
    }

    // MARK: Drawing primitives

    func surfaceMesh(_ s: Surface, transform T: (V2) -> V2) -> [Float] {
        let n = (s.cols * s.rows) <= 1 ? 32 : max(6, 48 / max(s.cols, s.rows))
        var out: [Float] = []
        out.reserveCapacity(s.cols * s.rows * n * n * 36)
        let crop = s.crop
        let warp = s.warp
        for cj in 0..<s.rows {
            for ci in 0..<s.cols {
                var grid: [V2] = []
                var st: [V2] = []
                grid.reserveCapacity((n + 1) * (n + 1))
                for b in 0...n {
                    for a in 0...n {
                        let u = Double(a) / Double(n), v = Double(b) / Double(n)
                        let q = V2((Double(ci) + u) / Double(s.cols), (Double(cj) + v) / Double(s.rows))
                        grid.append(T(warp.apply(q)))
                        st.append(q)
                    }
                }
                func emit(_ k: Int) {
                    let p = grid[k], q = st[k]
                    out += [Float(p.x), Float(p.y),
                            Float(crop.x + q.x * crop.w), Float(crop.y + q.y * crop.h),
                            Float(q.x), Float(q.y)]
                }
                for b in 0..<n {
                    for a in 0..<n {
                        let k0 = b * (n + 1) + a, k1 = k0 + 1, k2 = k0 + n + 2, k3 = k0 + n + 1
                        emit(k0); emit(k1); emit(k2); emit(k0); emit(k2); emit(k3)
                    }
                }
            }
        }
        return out
    }

    func drawSurface(_ enc: MTLRenderCommandEncoder, _ s: Surface, transform T: (V2) -> V2, texture: MTLTexture?, xf: Xf) {
        guard let texture, s.opacity > 0 else { return }
        let v = surfaceMesh(s, transform: T)
        drawTextured(enc, v, texture: texture, xf: xf,
                     uniforms: TexUniforms(opacity: Float(s.opacity), feather: Float(s.feather), brightness: Float(s.brightness)))
    }

    func drawMasks(_ enc: MTLRenderCommandEncoder, _ masks: [Mask], transform T: (V2) -> V2, unit: V2, xf: Xf) {
        var b = ColorBatch(unit: unit)
        for m in masks where m.visible {
            let pts = m.points.map(T)
            let tris = triangulate(pts)
            var k = 0
            while k + 2 < tris.count {
                b.tri(pts[tris[k]], pts[tris[k + 1]], pts[tris[k + 2]], Palette.black)
                k += 3
            }
        }
        drawBatch(enc, b, xf: xf)
    }

    func drawTextured(_ enc: MTLRenderCommandEncoder, _ v: [Float], texture: MTLTexture, xf: Xf, uniforms: TexUniforms) {
        guard !v.isEmpty, let buf = device.makeBuffer(bytes: v, length: v.count * 4, options: .storageModeShared) else { return }
        var xf = xf, u = uniforms
        enc.setRenderPipelineState(texPipe)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&xf, length: MemoryLayout<Xf>.stride, index: 1)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<TexUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: v.count / 6)
    }

    /// Draws a whole texture as the unit square.
    func drawImage(_ enc: MTLRenderCommandEncoder, _ texture: MTLTexture, xf: Xf) {
        let v: [Float] = [0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1,
                          0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1]
        drawTextured(enc, v, texture: texture, xf: xf, uniforms: TexUniforms())
    }

    func drawBatch(_ enc: MTLRenderCommandEncoder, _ b: ColorBatch, xf: Xf) {
        guard !b.isEmpty, let buf = device.makeBuffer(bytes: b.v, length: b.v.count * 4, options: .storageModeShared) else { return }
        var xf = xf
        enc.setRenderPipelineState(colPipe)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&xf, length: MemoryLayout<Xf>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: b.vertexCount)
    }
}

// MARK: - Guides shared by the editor and the projector

enum Guides {
    /// Mapping guides in projector-normalized space. Sizes are in units of `b.unit`.
    static func build(_ b: inout ColorBatch, project: Project, selection: Selection, selectedPoint: Int?, scale: Double = 1) {
        b.polyline(LaserSettings.unitCorners, closed: true, 1 * scale, RGBA(1, 1, 1, 0.25))
        for m in project.masks {
            let sel = selection == .mask(m.id)
            b.polyline(m.points, closed: true, (sel ? 2 : 1) * scale, sel ? Palette.mask : Palette.mask * RGBA(1, 1, 1, 0.6))
        }
        for s in project.surfaces where selection != .surface(s.id) {
            b.polyline(s.outline(), closed: false, 1 * scale, s.visible ? Palette.dim : RGBA(1, 1, 1, 0.2))
        }
        if case .surface(let id) = selection, let s = project.surfaces.first(where: { $0.id == id }) {
            let gridCol = RGBA(0.2, 0.85, 1, 0.45)
            let w = s.warp, ns = s.cols * 8, nt = s.rows * 8
            for j in 1..<max(1, s.rows) where s.rows > 1 {
                b.polyline((0...ns).map { w.apply(V2(Double($0) / Double(ns), Double(j) / Double(s.rows))) }, closed: false, 1 * scale, gridCol)
            }
            for i in 1..<max(1, s.cols) where s.cols > 1 {
                b.polyline((0...nt).map { w.apply(V2(Double(i) / Double(s.cols), Double($0) / Double(nt))) }, closed: false, 1 * scale, gridCol)
            }
            b.polyline(s.outline(), closed: false, 2 * scale, Palette.accent)
            let corners = s.cornerIndices
            for (k, p) in s.points.enumerated() {
                if let ci = corners.firstIndex(of: k) { b.handle(p, 6.5 * scale, Palette.corner[ci]) }
                else { b.handle(p, 4.5 * scale, Palette.white) }
            }
            if let k = selectedPoint, k < s.points.count { b.ring(s.points[k], 11 * scale, 2 * scale, Palette.white) }
        }
        if case .mask(let id) = selection, let m = project.masks.first(where: { $0.id == id }) {
            for p in m.points { b.handle(p, 5 * scale, Palette.mask) }
            if let k = selectedPoint, k < m.points.count { b.ring(m.points[k], 10 * scale, 2 * scale, Palette.white) }
        }
    }

    /// Laser calibration handles in laser-normalized space.
    static func buildLaser(_ b: inout ColorBatch, project: Project, selectedPoint: Int?) {
        b.polyline(LaserSettings.unitCorners, closed: true, 1, RGBA(1, 1, 1, 0.25))
        let cal = project.laser.calibration
        let lineCol = RGBA(1, 0.9, 0.2, 0.6)
        for j in 0...cal.rows { b.polyline((0...cal.cols).map { cal.point($0, j) }, closed: false, 1.5, lineCol) }
        for i in 0...cal.cols { b.polyline((0...cal.rows).map { cal.point(i, $0) }, closed: false, 1.5, lineCol) }
        for (k, p) in cal.points.enumerated() { b.handle(p, 7, Palette.calib(k)) }
        if let k = selectedPoint, k < cal.count { b.ring(cal.points[k], 12, 2, Palette.white) }
    }
}
