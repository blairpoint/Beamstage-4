import AppKit
import SwiftUI
import MetalKit
import simd

/// Letterboxed view of the projector composite (or laser feed) with editing handles.
final class EditorView: MTKView, MTKViewDelegate {
    weak var model: AppModel?
    var renderer: Renderer!

    private enum Drag {
        case none
        case surfacePoint(UUID, Int)
        case maskPoint(UUID, Int)
        case wholeSurface(UUID, V2, [V2])
        case wholeMask(UUID, V2, [V2])
        case laserCorner(Int)
        case laserAll(V2, [V2])
    }
    private var drag: Drag = .none
    private var dragCheckpointed = false
    private var calibrating = false

    init(renderer: Renderer, model: AppModel) {
        self.renderer = renderer
        self.model = model
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.075, green: 0.078, blue: 0.09, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        registerForDraggedTypes([.fileURL])
    }

    required init(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    private var aspect: Double {
        guard let p = model?.project else { return 16 / 9 }
        if model?.editorMode == .laser { return Double(p.laser.width) / Double(max(1, p.laser.height)) }
        return Double(p.outputWidth) / Double(max(1, p.outputHeight))
    }

    /// Points per normalized unit vertically, and the centre, in view points (y down).
    private func layout() -> (a: Double, s: Double, cx: Double, cy: Double) {
        let W = Double(bounds.width), H = Double(bounds.height)
        let a = aspect, m = 0.06
        let s = max(1, min((W - 24) / ((1 + 2 * m) * a), (H - 24) / (1 + 2 * m)))
        return (a, s, W / 2, H / 2)
    }

    private func xf() -> Xf {
        let (a, s, cx, cy) = layout()
        let W = Double(bounds.width), H = Double(bounds.height)
        return Xf(scale: SIMD2(Float(2 * a * s / W), Float(-2 * s / H)),
                  offset: SIMD2(Float(2 * (cx - 0.5 * a * s) / W - 1), Float(1 - 2 * (cy - 0.5 * s) / H)))
    }

    private func unit() -> V2 {
        let (a, s, _, _) = layout()
        return V2(1 / (a * s), 1 / s)
    }

    private func norm(_ e: NSEvent) -> V2 {
        let p = convert(e.locationInWindow, from: nil)
        let (a, s, cx, cy) = layout()
        let py = Double(bounds.height) - Double(p.y)
        return V2((Double(p.x) - cx) / (a * s) + 0.5, (py - cy) / s + 0.5)
    }

    /// Distance between two normalized points, in view points.
    private func dist(_ p: V2, _ q: V2) -> Double {
        let (a, s, _, _) = layout()
        return simd_length(V2((p.x - q.x) * a * s, (p.y - q.y) * s))
    }

    // MARK: Drawing

    func render() {
        guard let w = window, w.occlusionState.contains(.visible), bounds.width > 1 else { return }
        draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let model, let rpd = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cb = renderer.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let xf = xf()
        var b = ColorBatch(unit: unit())
        if model.editorMode == .laser {
            if let t = renderer.laserTex { renderer.drawImage(enc, t, xf: xf) }
            Guides.buildLaser(&b, project: model.project, selectedPoint: model.laserPoint)
        } else {
            if let t = renderer.comp { renderer.drawImage(enc, t, xf: xf) }
            Guides.build(&b, project: model.project, selection: model.selection, selectedPoint: model.selectedPoint)
        }
        renderer.drawBatch(enc, b, xf: xf)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model else { return }
        let q = norm(e)
        dragCheckpointed = false
        let r = 12.0

        if model.isCalibrating && model.editorMode == .projector {
            calibrating = true
            model.calibPress(at: q)
            return
        }
        calibrating = false

        if model.editorMode == .laser {
            let cal = model.project.laser.calibration
            let c = cal.points
            let outline = [cal.point(0, 0), cal.point(cal.cols, 0), cal.point(cal.cols, cal.rows), cal.point(0, cal.rows)]
            if let k = nearest(c, q, r) {
                model.laserPoint = k; drag = .laserCorner(k)
            } else if pointInPolygon(q, outline) {
                // While calibrating keep the current point, so a stray click doesn't lose your place.
                if !model.isCalibrating { model.laserPoint = nil }
                drag = .laserAll(q, c)
            } else {
                if !model.isCalibrating { model.laserPoint = nil }
                drag = .none
            }
            return
        }

        let p = model.project
        let option = e.modifierFlags.contains(.option)

        // Points of the selected item win over everything else.
        if let i = model.selectedSurfaceIndex, let k = nearest(p.surfaces[i].points, q, r) {
            model.selectedPoint = k; drag = .surfacePoint(p.surfaces[i].id, k); return
        }
        if let i = model.selectedMaskIndex {
            if let k = nearest(p.masks[i].points, q, r) {
                if option { model.selectedPoint = k; model.removeMaskPoint(k); drag = .none; return }
                model.selectedPoint = k; drag = .maskPoint(p.masks[i].id, k); return
            }
            if e.clickCount == 2 {
                let pts = p.masks[i].points
                let onEdge = pts.indices.contains { k in
                    let a = pts[k], bb = pts[(k + 1) % pts.count]
                    return distanceToSegment(q, a, bb) * layout().s < 10
                }
                if onEdge || pointInPolygon(q, pts) {
                    model.insertMaskPoint(near: q, maskIndex: i)
                    if let k = model.selectedPoint { drag = .maskPoint(p.masks[i].id, k) }
                    dragCheckpointed = true
                    return
                }
            }
        }
        // Then any point, top-most first.
        for s in p.surfaces.reversed() where s.visible {
            if let k = nearest(s.cornerIndices.map { s.points[$0] }, q, r) {
                model.selection = .surface(s.id); model.selectedPoint = s.cornerIndices[k]
                drag = .surfacePoint(s.id, s.cornerIndices[k]); return
            }
        }
        for m in p.masks.reversed() where m.visible {
            if pointInPolygon(q, m.points) {
                model.selection = .mask(m.id); model.selectedPoint = nil
                drag = .wholeMask(m.id, q, m.points); return
            }
        }
        // Prefer the selected surface when clicking inside overlapping surfaces.
        if let i = model.selectedSurfaceIndex, p.surfaces[i].contains(q) {
            model.selectedPoint = nil
            drag = .wholeSurface(p.surfaces[i].id, q, p.surfaces[i].points); return
        }
        for s in p.surfaces.reversed() where s.visible && s.contains(q) {
            model.selection = .surface(s.id); model.selectedPoint = nil
            drag = .wholeSurface(s.id, q, s.points); return
        }
        model.selection = .none; model.selectedPoint = nil; drag = .none
    }

    private func nearest(_ pts: [V2], _ q: V2, _ r: Double) -> Int? {
        guard let k = pts.indices.min(by: { dist(pts[$0], q) < dist(pts[$1], q) }), dist(pts[k], q) < r else { return nil }
        return k
    }

    override func mouseDragged(with e: NSEvent) {
        guard let model else { return }
        if calibrating { model.calibDrag(to: norm(e)); return }
        if case .none = drag { return }
        if !dragCheckpointed { model.checkpoint(); dragCheckpointed = true }
        var q = norm(e)
        q = V2(min(max(q.x, -0.5), 1.5), min(max(q.y, -0.5), 1.5))
        switch drag {
        case .none: break
        case .surfacePoint(let id, let k):
            if let i = model.project.surfaces.firstIndex(where: { $0.id == id }) { model.project.surfaces[i].points[k] = q }
        case .maskPoint(let id, let k):
            if let i = model.project.masks.firstIndex(where: { $0.id == id }), k < model.project.masks[i].points.count {
                model.project.masks[i].points[k] = q
            }
        case .wholeSurface(let id, let start, let orig):
            if let i = model.project.surfaces.firstIndex(where: { $0.id == id }) {
                let d = q - start
                model.project.surfaces[i].points = orig.map { $0 + d }
            }
        case .wholeMask(let id, let start, let orig):
            if let i = model.project.masks.firstIndex(where: { $0.id == id }) {
                let d = q - start
                model.project.masks[i].points = orig.map { $0 + d }
            }
        case .laserCorner(let k):
            if k < model.project.laser.calibration.points.count { model.project.laser.calibration.points[k] = q }
        case .laserAll(let start, let orig):
            let d = q - start
            model.project.laser.calibration.points = orig.map { $0 + d }
        }
    }

    override func mouseUp(with e: NSEvent) {
        if calibrating { model?.calibRelease(at: norm(e)); calibrating = false }
        drag = .none
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        if let proj = urls.first(where: { $0.pathExtension.lowercased() == "beamstage" }) {
            AppController.shared.openProject(at: proj)
            return true
        }
        model?.addMedia(urls)
        return true
    }
}

// MARK: - Projector output

final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OutputView: MTKView, MTKViewDelegate {
    weak var model: AppModel?
    var renderer: Renderer!
    var onDoubleClick: (() -> Void)?
    private var popup: NSHostingView<CalibrationPopup>?
    private var popupAtTop = false
    private lazy var blankCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()

    init(renderer: Renderer, model: AppModel) {
        self.renderer = renderer
        self.model = model
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        let h = NSHostingView(rootView: CalibrationPopup(model: model, scale: 1.5))
        h.isHidden = true
        addSubview(h)
        popup = h
    }

    required init(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // During calibration the pointer is shown (and drawn large) so you can aim at the wall.
    override func resetCursorRects() {
        if model?.calibSession == true { addCursorRect(bounds, cursor: .crosshair) }
        else { addCursorRect(bounds, cursor: blankCursor) }
    }

    private func norm(_ e: NSEvent) -> V2 {
        let p = convert(e.locationInWindow, from: nil)
        return V2(Double(p.x / max(1, bounds.width)), 1 - Double(p.y / max(1, bounds.height)))
    }

    override func mouseMoved(with e: NSEvent) { if model?.calibSession == true { model?.calibCursor = norm(e) } }
    override func mouseExited(with e: NSEvent) { model?.calibCursor = nil }

    override func mouseDown(with e: NSEvent) {
        guard let model else { return }
        if model.isCalibrating { model.calibCursor = norm(e); model.calibPress(at: norm(e)); return }
        if e.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let model, model.isCalibrating else { return }
        model.calibCursor = norm(e)
        model.calibDrag(to: norm(e))
    }

    override func mouseUp(with e: NSEvent) {
        guard let model, model.isCalibrating else { return }
        model.calibRelease(at: norm(e))
    }

    func render() {
        guard let w = window, w.occlusionState.contains(.visible), bounds.width > 1 else { return }
        layoutPopup()
        draw()
    }

    /// Keeps the step panel on the projection, on the opposite half from the active point.
    private func layoutPopup() {
        guard let popup, let model else { return }
        let show = model.calibSession
        if popup.isHidden == show { popup.isHidden = !show; window?.invalidateCursorRects(for: self) }
        guard show else { return }
        if let t = model.calibTarget { popupAtTop = t.y > 0.5 }
        else if !model.isCalibrating { popupAtTop = false }
        let size = popup.fittingSize
        let margin = bounds.height * 0.04
        let y = popupAtTop ? bounds.height - size.height - margin : margin
        let f = NSRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height).integral
        if popup.frame != f { popup.frame = f }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let model, let rpd = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cb = renderer.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        if let t = renderer.comp { renderer.drawImage(enc, t, xf: .full) }
        if model.showGuides && !model.projectorBlackout {
            let u = V2(1 / Double(max(1, bounds.width)), 1 / Double(max(1, bounds.height)))
            var b = ColorBatch(unit: u)
            Guides.build(&b, project: model.project, selection: model.selection, selectedPoint: model.selectedPoint, scale: 1.4)
            renderer.drawBatch(enc, b, xf: .full)
        }
        if model.calibSession, let c = model.calibCursor {
            // A big reticle so the pointer is easy to find on the wall.
            let u = V2(1 / Double(max(1, bounds.width)), 1 / Double(max(1, bounds.height)))
            var b = ColorBatch(unit: u)
            b.ring(c, 26, 5, RGBA(0, 0, 0, 0.7))
            b.ring(c, 26, 2.5, Palette.white)
            b.line(c - V2(40 * u.x, 0), c - V2(12 * u.x, 0), 2.5, Palette.white)
            b.line(c + V2(12 * u.x, 0), c + V2(40 * u.x, 0), 2.5, Palette.white)
            b.line(c - V2(0, 40 * u.y), c - V2(0, 12 * u.y), 2.5, Palette.white)
            b.line(c + V2(0, 12 * u.y), c + V2(0, 40 * u.y), 2.5, Palette.white)
            renderer.drawBatch(enc, b, xf: .full)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

final class OutputController: NSObject, NSWindowDelegate {
    private(set) var window: OutputWindow?
    private(set) var view: OutputView?
    private var windowedFrame: NSRect?
    private(set) var fullscreen = false
    private let renderer: Renderer
    private let model: AppModel

    init(renderer: Renderer, model: AppModel) {
        self.renderer = renderer
        self.model = model
    }

    var screen: NSScreen? { window?.screen }

    func open(on screen: NSScreen?) {
        if window == nil {
            let w = OutputWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 540),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Beamstage Output"
            w.isReleasedWhenClosed = false
            w.backgroundColor = .black
            w.delegate = self
            w.collectionBehavior = [.fullScreenAuxiliary, .managed]
            let v = OutputView(renderer: renderer, model: model)
            v.onDoubleClick = { [weak self] in self?.toggleFullscreen() }
            w.contentView = v
            window = w; view = v
        }
        guard let window else { return }
        if let screen {
            if screen != AppController.shared.mainWindow?.screen {
                // A projector: go borderless across the whole display.
                setFullscreen(true, on: screen)
            } else {
                // Same screen as the controls: open as a window (double-click it to fill the screen).
                if fullscreen { setFullscreen(false) }
                let f = screen.visibleFrame
                window.setFrame(NSRect(x: f.midX - 480, y: f.midY - 270, width: 960, height: 540), display: true)
            }
        } else if !fullscreen {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        model.outputOpen = true
    }

    func setFullscreen(_ on: Bool, on target: NSScreen? = nil) {
        guard let window else { return }
        if on {
            let scr = target ?? window.screen ?? NSScreen.main
            guard let scr else { return }
            if !fullscreen { windowedFrame = window.frame }
            window.styleMask = [.borderless]
            window.level = .mainMenu + 1
            window.setFrame(scr.frame, display: true)
            fullscreen = true
        } else {
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.level = .normal
            window.setFrame(windowedFrame ?? NSRect(x: 120, y: 120, width: 960, height: 540), display: true)
            window.title = "Beamstage Output"
            fullscreen = false
        }
        window.makeKeyAndOrderFront(nil)
        window.invalidateCursorRects(for: view!)
    }

    func toggleFullscreen() { setFullscreen(!fullscreen) }

    /// Leave fullscreen if the output is covering the control window's screen.
    func releaseControlScreen(_ control: NSWindow?) {
        guard fullscreen, let s = window?.screen, s == control?.screen else { return }
        setFullscreen(false)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        fullscreen = false
        window = nil; view = nil
        model.outputOpen = false
    }
}
