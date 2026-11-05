import AppKit
import SwiftUI
import ImageIO
import Metal
import Syphon
import UniformTypeIdentifiers
import simd

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

/// Copies a private texture back to the CPU and writes it as a PNG.
func writePNG(_ tex: MTLTexture, renderer: Renderer, to url: URL) {
    let bpr = tex.width * 4
    guard let buf = renderer.device.makeBuffer(length: bpr * tex.height, options: .storageModeShared),
          let cb = renderer.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { fail("readback failed") }
    blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
              to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * tex.height)
    blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(data: buf.contents(), width: tex.width, height: tex.height, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: cs, bitmapInfo: info), let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("png failed") }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

func runCheck() -> Never {
    guard let device = MTLCreateSystemDefaultDevice() else { fail("error no Metal device") }
    let lib = MediaLibrary(device: device)
    guard let r = Renderer(device: device, library: lib, syphon: false) else { fail("error renderer failed to start") }
    let server = SyphonMetalServer(name: "Beamstage Check", device: device, options: nil)
    guard let t = r.makeTarget(width: 64, height: 64), let cb = r.queue.makeCommandBuffer() else { fail("error no texture") }
    r.encodeScene(cb, target: t, project: .starter(), kind: .projector, selected: nil, blackout: false)
    server.publishFrameTexture(t, on: cb, imageRegion: NSRect(x: 0, y: 0, width: 64, height: 64), flipped: false)
    cb.commit(); cb.waitUntilCompleted()
    server.stop()
    print("ok Syphon server started and published a test frame")
    exit(0)
}

/// Renders a sample project to PNGs: beamstage --render-test <dir> [media file]
func runRenderTest(_ args: [String]) -> Never {
    guard args.count >= 1 else { fail("usage: --render-test <outdir> [media]") }
    let out = URL(fileURLWithPath: args[0], isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
    let lib = MediaLibrary(device: device)
    guard let r = Renderer(device: device, library: lib, syphon: false) else { fail("renderer failed") }

    var p = Project.starter()
    p.surfaces[0].points = Surface.gridPoints(corners: [V2(0.05, 0.08), V2(0.55, 0.02), V2(0.5, 0.6), V2(0.1, 0.5)], cols: 1, rows: 1)
    if args.count >= 2 {
        let m = MediaRef(path: args[1], name: (args[1] as NSString).lastPathComponent)
        p.media.append(m)
        var s = Surface.make(name: "Clip", media: m.id, corners: [V2(0.6, 0.3), V2(0.95, 0.25), V2(0.97, 0.9), V2(0.58, 0.8)])
        s.resample(cols: 3, rows: 2)
        s.points[5] += V2(0.04, 0.0)   // bend an interior point
        s.feather = 0.08
        p.surfaces.append(s)
    }
    p.masks = [Mask(name: "Mask", points: [V2(0.25, 0.25), V2(0.35, 0.22), V2(0.33, 0.35), V2(0.28, 0.3), V2(0.22, 0.34)])]
    p.laser.calibration = p.laser.calibration.resampled(cols: 2, rows: 2)
    p.laser.calibration.points = p.laser.calibration.points.map { V2(0.5 + ($0.x - 0.5) * 1.05, 0.5 + ($0.y - 0.5) * 0.95) }
    p.laser.calibration.points[4] += V2(0.03, 0.02)   // bend the middle, like lens distortion

    lib.sync(p.media)
    if args.count >= 2 && lib.missing.contains(p.media[0].id) { fail("could not load \(args[1])") }
    // Give video a moment to produce a first frame.
    let start = Date()
    while Date().timeIntervalSince(start) < 1.5 {
        lib.update(now: CACurrentMediaTime(), playing: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func render(_ name: String, _ kind: SceneKind, _ mode: LaserMode? = nil, test: TestState = TestState()) {
        var q = p
        if let mode { q.laser.mode = mode }
        let w = kind == .projector ? q.outputWidth : q.laser.width
        let h = kind == .projector ? q.outputHeight : q.laser.height
        guard let t = r.makeTarget(width: w, height: h), let cb = r.queue.makeCommandBuffer() else { fail("target") }
        r.encodeScene(cb, target: t, project: q, kind: kind, selected: q.surfaces.last?.id, blackout: false, test: test)
        cb.commit(); cb.waitUntilCompleted()
        writePNG(t, renderer: r, to: out.appendingPathComponent(name + ".png"))
        print("wrote \(name).png \(w)x\(h)")
    }
    render("projector", .projector)
    render("projector-align", .projector, .align)
    for m in LaserMode.allCases { render("laser-\(m.rawValue)", .laser, m) }
    for t in [LaserTest.calibrate, .outlines, .grid] {
        let ts = TestState(test: t, active: t == .calibrate ? 4 : nil)
        render("test-\(t.rawValue)-projector", .projector, test: ts)
        render("test-\(t.rawValue)-laser", .laser, test: ts)
    }
    // Old projects stored four laser corners; they must load into the new calibration.
    let legacy = #"{"mode":"outlines","width":1280,"height":720,"fps":30,"flipX":false,"flipY":false,"lineWidth":3,"corners":[[0.1,0.1],[0.9,0.1],[0.9,0.9],[0.1,0.9]]}"#
    guard let old = try? JSONDecoder().decode(LaserSettings.self, from: Data(legacy.utf8)) else { fail("legacy laser settings failed to load") }
    if simd_length(old.makeTransform()(V2(0, 0)) - V2(0.1, 0.1)) > 1e-9 || simd_length(old.makeTransform()(V2(1, 1)) - V2(0.9, 0.9)) > 1e-9 {
        fail("legacy laser corners not migrated")
    }
    // Resampling the calibration must not change the correction.
    let m1 = p.laser.calibration.makeMap(), c2 = p.laser.calibration.resampled(cols: 4, rows: 4)
    let m2 = c2.makeMap()
    for t in p.laser.calibration.targets where simd_length(m1(t) - m2(t)) > 1e-9 { fail("calibration resample moved a point") }

    // Geometry sanity: homography round trip and grid resampling keep the shape.
    let q = [V2(0.1, 0.2), V2(0.8, 0.1), V2(0.9, 0.7), V2(0.2, 0.9)]
    let h = Homography.squareToQuad(q)
    for (i, c) in LaserSettings.unitCorners.enumerated() where simd_length(h.apply(c) - q[i]) > 1e-9 { fail("homography corner \(i) wrong") }
    var s = Surface.make(name: "t", media: nil, corners: q)
    let mid = s.eval(0.5, 0.5)
    s.resample(cols: 4, rows: 4)
    if simd_length(s.eval(0.5, 0.5) - mid) > 1e-9 || simd_length(s.p(2, 2) - mid) > 1e-9 { fail("resample moved the surface") }
    if triangulate([V2(0, 0), V2(1, 0), V2(1, 1), V2(0.5, 0.4), V2(0, 1)]).count != 9 { fail("triangulate concave failed") }
    // Click calibration: a simulated laser (laser coords -> wall) is off by a keystone and an
    // offset. Clicking where its cross appears must bring every cross onto its target.
    for flip in [false, true] {
        let m = AppModel()
        m.project.laser.flipX = flip
        m.setCalibrationGrid(3)
        let wall = Homography.squareToQuad([V2(0.07, 0.12), V2(0.95, 0.03), V2(0.9, 0.97), V2(0.02, 0.88)])
        let laserToWall: (V2) -> V2 = { l in wall.apply(flip ? V2(1 - l.x, l.y) : l) }
        m.startCalibration()
        var worst = 0.0
        for k in 0..<m.project.laser.calibration.count {
            m.laserPoint = k
            for _ in 0..<4 {
                let seen = laserToWall(m.project.laser.calibration.points[k])
                m.calibPress(at: seen); m.calibRelease(at: seen)
            }
            worst = max(worst, simd_length(laserToWall(m.project.laser.calibration.points[k]) - m.calibTarget!))
        }
        if worst > 0.002 { fail("click calibration did not converge (flip \(flip)): \(worst)") }
        print("ok click calibration converges, flip \(flip), worst error \(String(format: "%.5f", worst))")
        // Drag: moving the mouse right must move the laser cross right on the wall.
        m.redoCalibration()
        let before = laserToWall(m.project.laser.calibration.points[0])
        m.calibPress(at: V2(0.5, 0.5)); m.calibDrag(to: V2(0.55, 0.5)); m.calibRelease(at: V2(0.55, 0.5))
        let moved = laserToWall(m.project.laser.calibration.points[0]) - before
        if moved.x <= 0 || abs(moved.y) > abs(moved.x) { fail("drag moved the laser the wrong way (flip \(flip))") }
        m.cancelCalibration()
    }
    print("ok geometry checks passed")
    exit(0)
}

/// Renders the calibration popup offscreen: beamstage --render-popup <dir>
func runRenderPopup(_ dir: String) -> Never {
    _ = NSApplication.shared
    let m = AppModel()
    m.setCalibrationGrid(3)
    func shot(_ name: String) {
        let v = NSHostingView(rootView: CalibrationPopup(model: m, scale: 1.5))
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { fail("no rep") }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        print("wrote \(name) \(Int(v.bounds.width))x\(Int(v.bounds.height))")
    }
    m.startCalibration(); m.laserPoint = 3
    shot("popup-point.png")
    m.laserBlackout = true
    m.startCheck()
    shot("popup-check.png")
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--render-popup", args.count > 1 { runRenderPopup(args[1]) }
if args.first == "--check" { runCheck() }
if args.first == "--render-test" { runRenderTest(Array(args.dropFirst())) }

guard let device = MTLCreateSystemDefaultDevice() else {
    let a = NSAlert(); a.messageText = "Beamstage needs a Mac with Metal graphics."; a.runModal()
    exit(1)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
guard let controller = AppController(device: device) else { fail("Beamstage could not start its renderer") }
AppController.shared = controller
app.delegate = controller
app.run()
