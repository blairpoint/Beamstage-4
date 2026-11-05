import AppKit
import Combine
import Foundation
import SwiftUI
import simd

enum MediaKind: String, Codable { case file, testPattern, white }

struct MediaRef: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: MediaKind = .file
    var path = ""
    var name = ""
    var muted = false
}

struct Crop: Codable, Equatable { var x = 0.0, y = 0.0, w = 1.0, h = 1.0 }

struct Surface: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var mediaID: UUID?
    var cols = 1
    var rows = 1
    var points: [V2]
    var crop = Crop()
    var opacity = 1.0
    var feather = 0.0
    var brightness = 1.0
    var visible = true
    var toLaser = true

    static func make(name: String, media: UUID?, corners: [V2]) -> Surface {
        Surface(name: name, mediaID: media, points: Surface.gridPoints(corners: corners, cols: 1, rows: 1))
    }
}

struct Mask: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var points: [V2]
    var visible = true
}

enum LaserMode: String, Codable, CaseIterable, Identifiable {
    case outlines, silhouettes, projection, selected, align
    var id: String { rawValue }
    var label: String {
        switch self {
        case .outlines: return "Surface outlines"
        case .silhouettes: return "Filled surfaces"
        case .projection: return "Projection output"
        case .selected: return "Selected surface"
        case .align: return "Calibration crosses"
        }
    }
    var help: String {
        switch self {
        case .outlines: return "White edges of each surface marked “Send to laser”, on black. Cleanest for laser tracing."
        case .silhouettes: return "Each laser surface filled solid white, so the tracer draws one outline per shape."
        case .projection: return "Exactly what the projector shows, warped for the laser."
        case .selected: return "Only the selected surface's video, in place."
        case .align: return "A cross on every calibration point. The projector shows the same crosses."
        }
    }
}

/// Where a regular grid of projector targets lands in the laser feed.
/// Targets sit inside the frame (inset) so their crosses are fully visible;
/// points outside the grid are extrapolated from the edge cells.
struct LaserCalibration: Codable, Equatable {
    static let inset = 0.1
    var cols = 1
    var rows = 1
    var points: [V2]   // laser-normalized, row-major, (cols+1)*(rows+1)

    static func identity(cols: Int = 1, rows: Int = 1) -> LaserCalibration {
        var c = LaserCalibration(cols: cols, rows: rows, points: [])
        c.points = c.targets
        return c
    }

    var count: Int { (cols + 1) * (rows + 1) }

    func target(_ i: Int, _ j: Int) -> V2 {
        let span = 1 - 2 * LaserCalibration.inset
        return V2(LaserCalibration.inset + span * Double(i) / Double(cols),
                  LaserCalibration.inset + span * Double(j) / Double(rows))
    }

    /// Projector-space targets, row-major.
    var targets: [V2] {
        var t: [V2] = []
        for j in 0...rows { for i in 0...cols { t.append(target(i, j)) } }
        return t
    }

    func point(_ i: Int, _ j: Int) -> V2 { points[j * (cols + 1) + i] }

    /// Projector point (before flips) -> laser point. Exact at every calibration point and
    /// continuous between them; with 2 × 2 points it is a pure perspective transform.
    func makeMap() -> (V2) -> V2 {
        let warp = GridWarp(cols: cols, rows: rows, points: points)
        let inset = LaserCalibration.inset, span = 1 - 2 * inset
        return { p in warp.apply(V2((p.x - inset) / span, (p.y - inset) / span)) }
    }

    /// Change the number of calibration points, keeping the current correction.
    func resampled(cols nc: Int, rows nr: Int) -> LaserCalibration {
        let map = makeMap()
        var n = LaserCalibration(cols: max(1, nc), rows: max(1, nr), points: [])
        n.points = n.targets.map(map)
        return n
    }

    /// True when the cells are plain projective (no bend between points).
    var isFourPoint: Bool { cols == 1 && rows == 1 }
}

struct LaserSettings: Codable, Equatable {
    static let unitCorners: [V2] = [V2(0, 0), V2(1, 0), V2(1, 1), V2(0, 1)]
    var mode: LaserMode = .outlines
    var width = 1280
    var height = 720
    var fps = 30
    var flipX = false
    var flipY = false
    var calibration = LaserCalibration.identity()
    var lineWidth = 3.0

    init() {}

    private enum CodingKeys: String, CodingKey { case mode, width, height, fps, flipX, flipY, calibration, lineWidth, corners }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(LaserMode.self, forKey: .mode)) ?? .outlines
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1280
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 720
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 30
        flipX = try c.decodeIfPresent(Bool.self, forKey: .flipX) ?? false
        flipY = try c.decodeIfPresent(Bool.self, forKey: .flipY) ?? false
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 3
        if let cal = try c.decodeIfPresent(LaserCalibration.self, forKey: .calibration), cal.points.count == cal.count {
            calibration = cal
        } else if let old = try c.decodeIfPresent([V2].self, forKey: .corners), old.count == 4 {
            // Earlier 4.0 projects stored where the frame corners landed.
            let h = Homography.squareToQuad(old)
            var cal = LaserCalibration.identity()
            cal.points = cal.targets.map(h.apply)
            calibration = cal
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(fps, forKey: .fps)
        try c.encode(flipX, forKey: .flipX)
        try c.encode(flipY, forKey: .flipY)
        try c.encode(calibration, forKey: .calibration)
        try c.encode(lineWidth, forKey: .lineWidth)
    }

    /// Projector-normalized point -> laser (Syphon) normalized point.
    func makeTransform() -> (V2) -> V2 {
        let map = calibration.makeMap()
        let fx = flipX, fy = flipY
        return { p in
            var q = p
            if fx { q.x = 1 - q.x }
            if fy { q.y = 1 - q.y }
            return map(q)
        }
    }
}

/// Test patterns that override the laser feed and overlay the projector.
enum LaserTest: String, CaseIterable, Identifiable {
    case off, calibrate, outlines, grid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .calibrate: return "Calibrate"
        case .outlines: return "Outlines"
        case .grid: return "Grid"
        }
    }
}

struct Project: Codable, Equatable {
    var version = 4
    var outputWidth = 1920
    var outputHeight = 1080
    var media: [MediaRef] = []
    var surfaces: [Surface] = []
    var masks: [Mask] = []
    var laser = LaserSettings()

    static func starter() -> Project {
        var p = Project()
        p.surfaces = [Surface.make(name: "Surface 1", media: MediaLibrary.testPatternID, corners: LaserSettings.unitCorners)]
        return p
    }

    var allMedia: [MediaRef] {
        [MediaRef(id: MediaLibrary.testPatternID, kind: .testPattern, name: "Test pattern"),
         MediaRef(id: MediaLibrary.whiteID, kind: .white, name: "Solid white")] + media
    }
}


enum Selection: Equatable { case none, surface(UUID), mask(UUID) }
enum EditorMode: String { case projector, laser }

final class AppModel: ObservableObject {
    @Published var project = Project.starter()
    @Published var selection: Selection = .none
    @Published var selectedPoint: Int?
    @Published var laserPoint: Int?
    @Published var laserTest: LaserTest = .off
    @Published var blinkProjector = false
    private var calibrationBackup: LaserCalibration?
    @Published var editorMode: EditorMode = .projector
    @Published var playing = true
    @Published var showGuides = true
    @Published var projectorBlackout = false
    @Published var laserBlackout = false
    @Published var laserClients = false
    @Published var outputClients = false
    @Published var outputOpen = false
    @Published var projectURL: URL?
    @Published var missingMedia: Set<UUID> = []
    @Published var fps: Double = 0

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var lastTag = ""
    private var lastTagTime = 0.0

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Undo

    /// Records an undo step. Calls with the same non-empty tag within a second merge into one step.
    func checkpoint(_ tag: String = "") {
        let now = CACurrentMediaTime()
        if !tag.isEmpty && tag == lastTag && now - lastTagTime < 1.0 { lastTagTime = now; return }
        lastTag = tag; lastTagTime = now
        undoStack.append(project)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func edit(_ tag: String = "", _ f: (inout Project) -> Void) {
        checkpoint(tag)
        f(&project)
    }

    func undo() {
        guard let p = undoStack.popLast() else { return }
        redoStack.append(project); project = p; lastTag = ""; validateSelection()
    }

    func redo() {
        guard let p = redoStack.popLast() else { return }
        undoStack.append(project); project = p; lastTag = ""; validateSelection()
    }

    func replaceProject(_ p: Project, url: URL?) {
        project = p; projectURL = url
        undoStack.removeAll(); redoStack.removeAll()
        selection = p.surfaces.first.map { .surface($0.id) } ?? .none
        selectedPoint = nil
    }

    func validateSelection() {
        switch selection {
        case .surface(let id) where !project.surfaces.contains(where: { $0.id == id }): selection = .none
        case .mask(let id) where !project.masks.contains(where: { $0.id == id }): selection = .none
        default: break
        }
        selectedPoint = nil
    }

    // MARK: Lookup

    var selectedSurfaceIndex: Int? {
        if case .surface(let id) = selection { return project.surfaces.firstIndex { $0.id == id } }
        return nil
    }

    var selectedMaskIndex: Int? {
        if case .mask(let id) = selection { return project.masks.firstIndex { $0.id == id } }
        return nil
    }

    var selectedSurfaceID: UUID? {
        if case .surface(let id) = selection { return id }
        return nil
    }

    func surfaceBinding<T>(_ id: UUID, _ kp: WritableKeyPath<Surface, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { [unowned self] in self.project.surfaces.first { $0.id == id }?[keyPath: kp] ?? fallback },
            set: { [unowned self] v in
                guard let i = self.project.surfaces.firstIndex(where: { $0.id == id }) else { return }
                self.checkpoint("surface-\(id)-\(kp.hashValue)")
                self.project.surfaces[i][keyPath: kp] = v
            })
    }

    func maskBinding<T>(_ id: UUID, _ kp: WritableKeyPath<Mask, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { [unowned self] in self.project.masks.first { $0.id == id }?[keyPath: kp] ?? fallback },
            set: { [unowned self] v in
                guard let i = self.project.masks.firstIndex(where: { $0.id == id }) else { return }
                self.checkpoint("mask-\(id)-\(kp.hashValue)")
                self.project.masks[i][keyPath: kp] = v
            })
    }

    func projectBinding<T>(_ kp: WritableKeyPath<Project, T>) -> Binding<T> {
        Binding(
            get: { [unowned self] in self.project[keyPath: kp] },
            set: { [unowned self] v in
                self.checkpoint("project-\(kp.hashValue)")
                self.project[keyPath: kp] = v
            })
    }

    // MARK: Surfaces

    func addSurface() {
        let media = selectedSurfaceIndex.flatMap { project.surfaces[$0].mediaID } ?? project.media.first?.id ?? MediaLibrary.testPatternID
        let n = project.surfaces.count + 1
        let off = Double(n % 5) * 0.03
        let s = Surface.make(name: "Surface \(n)", media: media, corners: [
            V2(0.3 + off, 0.3 + off), V2(0.7 + off, 0.3 + off), V2(0.7 + off, 0.7 + off), V2(0.3 + off, 0.7 + off),
        ])
        edit { $0.surfaces.append(s) }
        selection = .surface(s.id); selectedPoint = nil
    }

    func duplicateSelected() {
        if let i = selectedSurfaceIndex {
            var s = project.surfaces[i]
            s.id = UUID(); s.name += " copy"
            s.points = s.points.map { $0 + V2(0.03, 0.03) }
            edit { $0.surfaces.insert(s, at: i + 1) }
            selection = .surface(s.id)
        } else if let i = selectedMaskIndex {
            var m = project.masks[i]
            m.id = UUID(); m.name += " copy"
            m.points = m.points.map { $0 + V2(0.03, 0.03) }
            edit { $0.masks.insert(m, at: i + 1) }
            selection = .mask(m.id)
        }
        selectedPoint = nil
    }

    func deleteSelected() {
        if let i = selectedSurfaceIndex { edit { $0.surfaces.remove(at: i) } }
        else if let i = selectedMaskIndex { edit { $0.masks.remove(at: i) } }
        selection = .none; selectedPoint = nil
    }

    func moveSelected(_ delta: Int) {
        if let i = selectedSurfaceIndex {
            let j = i + delta
            guard j >= 0, j < project.surfaces.count else { return }
            edit { $0.surfaces.swapAt(i, j) }
        } else if let i = selectedMaskIndex {
            let j = i + delta
            guard j >= 0, j < project.masks.count else { return }
            edit { $0.masks.swapAt(i, j) }
        }
    }

    func fillOutput() {
        guard let i = selectedSurfaceIndex else { return }
        edit {
            let s = $0.surfaces[i]
            $0.surfaces[i].points = Surface.gridPoints(corners: LaserSettings.unitCorners, cols: s.cols, rows: s.rows)
        }
    }

    func flattenGrid() {
        guard let i = selectedSurfaceIndex else { return }
        edit { $0.surfaces[i].flatten() }
    }

    func setGrid(cols: Int, rows: Int) {
        guard let i = selectedSurfaceIndex else { return }
        edit("grid") { $0.surfaces[i].resample(cols: cols, rows: rows) }
        selectedPoint = nil
    }

    // MARK: Masks

    func addMask() {
        let m = Mask(name: "Mask \(project.masks.count + 1)",
                     points: [V2(0.42, 0.42), V2(0.58, 0.42), V2(0.58, 0.58), V2(0.42, 0.58)])
        edit { $0.masks.append(m) }
        selection = .mask(m.id); selectedPoint = nil
    }

    /// Inserts a point in the middle of the edge after the selected point (or the longest edge).
    func addMaskPoint() {
        guard let i = selectedMaskIndex else { return }
        let pts = project.masks[i].points
        var k = selectedPoint ?? 0
        if selectedPoint == nil {
            var best = -1.0
            for e in 0..<pts.count {
                let l = simd_length(pts[(e + 1) % pts.count] - pts[e])
                if l > best { best = l; k = e }
            }
        }
        let mid = (pts[k] + pts[(k + 1) % pts.count]) / 2
        edit { $0.masks[i].points.insert(mid, at: k + 1) }
        selectedPoint = k + 1
    }

    func insertMaskPoint(near q: V2, maskIndex i: Int) {
        let pts = project.masks[i].points
        var best = Double.infinity, k = 0
        for e in 0..<pts.count {
            let d = distanceToSegment(q, pts[e], pts[(e + 1) % pts.count])
            if d < best { best = d; k = e }
        }
        edit { $0.masks[i].points.insert(q, at: k + 1) }
        selectedPoint = k + 1
    }

    func removeMaskPoint(_ p: Int? = nil) {
        guard let i = selectedMaskIndex, let k = p ?? selectedPoint else { return }
        guard project.masks[i].points.count > 3, k < project.masks[i].points.count else { NSSound.beep(); return }
        edit { $0.masks[i].points.remove(at: k) }
        selectedPoint = nil
    }

    // MARK: Media

    static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "gif", "png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp", "webp"]

    func addMedia(_ urls: [URL]) {
        let good = urls.filter { AppModel.mediaExtensions.contains($0.pathExtension.lowercased()) }
        guard !good.isEmpty else { NSSound.beep(); return }
        checkpoint()
        var added: [MediaRef] = []
        for u in good {
            if let existing = project.media.first(where: { $0.path == u.path }) { added.append(existing); continue }
            let r = MediaRef(path: u.path, name: u.lastPathComponent)
            project.media.append(r); added.append(r)
        }
        guard let first = added.first else { return }
        if project.surfaces.isEmpty {
            let s = Surface.make(name: "Surface 1", media: first.id, corners: LaserSettings.unitCorners)
            project.surfaces.append(s)
            selection = .surface(s.id)
        } else {
            // Give the new clip to the selected surface, or the first one still on a placeholder.
            let placeholder: (Surface) -> Bool = { s in
                s.mediaID == nil || s.mediaID == MediaLibrary.testPatternID || s.mediaID == MediaLibrary.whiteID
            }
            if let i = selectedSurfaceIndex, placeholder(project.surfaces[i]) {
                project.surfaces[i].mediaID = first.id
            } else if let i = project.surfaces.firstIndex(where: placeholder) {
                project.surfaces[i].mediaID = first.id
                selection = .surface(project.surfaces[i].id)
            }
        }
    }

    func removeMedia(_ id: UUID) {
        edit {
            $0.media.removeAll { $0.id == id }
            for i in $0.surfaces.indices where $0.surfaces[i].mediaID == id { $0.surfaces[i].mediaID = nil }
        }
    }

    func relinkMedia(_ id: UUID, to url: URL) {
        guard let i = project.media.firstIndex(where: { $0.id == id }) else { return }
        edit { $0.media[i].path = url.path; $0.media[i].name = url.lastPathComponent }
    }

    // MARK: Laser

    func resetLaserAlignment() {
        let c = project.laser.calibration
        edit { $0.laser.calibration = .identity(cols: c.cols, rows: c.rows) }
    }

    /// Grid of calibration points: 2 means 2×2 (four points), up to 5×5.
    func setCalibrationGrid(_ n: Int) {
        let n = max(2, min(n, 5))
        edit { $0.laser.calibration = $0.laser.calibration.resampled(cols: n - 1, rows: n - 1) }
        if let k = laserPoint, k >= project.laser.calibration.count { laserPoint = 0 }
    }

    // MARK: Calibration
    //
    // A session has two stages: placing points (laserTest == .calibrate), then a check
    // (laserTest == .grid or .outlines) with Done / Redo. All interaction happens in
    // projector space, on the output window or the editor: you point at where you see
    // the laser, and the laser point is corrected through the current transform.

    @Published var calibSession = false
    @Published var remoteOn = false
    @Published var remoteError: String?
    var isCalibrating: Bool { laserTest == .calibrate }
    var isCheckingCalibration: Bool { calibSession && !isCalibrating }

    /// Mouse position over the output while calibrating (not published: changes every frame).
    var calibCursor: V2?
    private var calibPressStart: V2?
    private var calibPressPoint: V2?
    private var calibPressMap: ((V2) -> V2)?
    private var calibDragging = false

    func startCalibration() {
        calibrationBackup = project.laser.calibration
        checkpoint()
        calibSession = true
        laserTest = .calibrate
        editorMode = .projector
        selection = .none; selectedPoint = nil
        laserPoint = 0
    }

    func startCheck() {
        if !calibSession { calibrationBackup = project.laser.calibration }
        calibSession = true
        laserTest = .grid
        editorMode = .projector
        laserPoint = nil
    }

    func stepCalibration(_ dir: Int) {
        let n = project.laser.calibration.count
        let k = (laserPoint ?? -1) + dir
        if k >= n { startCheck(); return }
        laserPoint = max(0, k)
    }

    func redoCalibration() {
        laserTest = .calibrate
        laserPoint = 0
    }

    func finishCalibration() {
        calibrationBackup = nil
        calibSession = false
        laserTest = .off
        laserPoint = nil
        calibCursor = nil
    }

    func cancelCalibration() {
        if let b = calibrationBackup { project.laser.calibration = b }
        calibrationBackup = nil
        calibSession = false
        laserTest = .off
        editorMode = .projector
        laserPoint = nil
        calibCursor = nil
    }

    /// Projector-space spot where the current point's crosses are meant to meet.
    var calibTarget: V2? {
        guard isCalibrating, let k = laserPoint, k < project.laser.calibration.count else { return nil }
        return Renderer.projectorTarget(project.laser, k)
    }

    func calibPress(at p: V2) {
        guard isCalibrating, let k = laserPoint, k < project.laser.calibration.count else { return }
        checkpoint()
        calibPressStart = p
        calibPressPoint = project.laser.calibration.points[k]
        calibPressMap = project.laser.makeTransform()
        calibDragging = false
    }

    /// Dragging moves the laser cross with the mouse, by the same distance on the wall.
    func calibDrag(to p: V2) {
        guard let start = calibPressStart, let l0 = calibPressPoint, let T = calibPressMap, let k = laserPoint else { return }
        let px = V2((p.x - start.x) * Double(project.outputWidth), (p.y - start.y) * Double(project.outputHeight))
        if !calibDragging && simd_length(px) < 6 { return }
        calibDragging = true
        project.laser.calibration.points[k] = l0 + T(p) - T(start)
    }

    /// A click (no drag) says "the laser cross is here": move it from there onto the target.
    func calibRelease(at p: V2) {
        defer { calibPressStart = nil; calibPressPoint = nil; calibPressMap = nil }
        guard !calibDragging, let l0 = calibPressPoint, let T = calibPressMap, let target = calibTarget, let k = laserPoint else {
            calibDragging = false; return
        }
        project.laser.calibration.points[k] = l0 + T(target) - T(p)
    }

    /// Arrow keys move the laser cross in projector pixels, whatever the flips.
    private func calibNudge(_ d: V2) {
        guard let k = laserPoint, let target = calibTarget else { return }
        let T = project.laser.makeTransform()
        let step = V2(d.x / Double(project.outputWidth), d.y / Double(project.outputHeight))
        edit("nudge-calib-\(k)") { $0.laser.calibration.points[k] += T(target + step) - T(target) }
    }

    // MARK: Nudging

    func nudge(_ d: V2) {
        if isCalibrating { calibNudge(d); return }
        if editorMode == .laser {
            let step = V2(d.x / Double(project.laser.width), d.y / Double(project.laser.height))
            edit("nudge-laser") { p in
                if let k = laserPoint, k < p.laser.calibration.points.count { p.laser.calibration.points[k] += step }
                else { p.laser.calibration.points = p.laser.calibration.points.map { $0 + step } }
            }
            return
        }
        let step = V2(d.x / Double(project.outputWidth), d.y / Double(project.outputHeight))
        if let i = selectedSurfaceIndex {
            edit("nudge-\(project.surfaces[i].id)") { p in
                if let k = selectedPoint, k < p.surfaces[i].points.count { p.surfaces[i].points[k] += step }
                else { p.surfaces[i].points = p.surfaces[i].points.map { $0 + step } }
            }
        } else if let i = selectedMaskIndex {
            edit("nudge-\(project.masks[i].id)") { p in
                if let k = selectedPoint, k < p.masks[i].points.count { p.masks[i].points[k] += step }
                else { p.masks[i].points = p.masks[i].points.map { $0 + step } }
            }
        }
    }

    func cyclePoint(_ dir: Int) {
        if editorMode == .laser {
            let n = project.laser.calibration.count
            laserPoint = ((laserPoint ?? (dir > 0 ? -1 : 0)) + dir + n) % n
            return
        }
        let count: Int
        if let i = selectedSurfaceIndex { count = project.surfaces[i].points.count }
        else if let i = selectedMaskIndex { count = project.masks[i].points.count }
        else { return }
        selectedPoint = ((selectedPoint ?? (dir > 0 ? -1 : 0)) + dir + count) % count
    }
}
