import AppKit
import Combine
import CoreVideo
import Metal
import SwiftUI
import UniformTypeIdentifiers

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    static var shared: AppController!

    let model = AppModel()
    let device: MTLDevice
    let library: MediaLibrary
    let renderer: Renderer
    private(set) var editor: EditorView!
    private(set) var output: OutputController!
    private(set) var mainWindow: NSWindow?
    private(set) var remote: RemoteServer!
    private var displayLink: CVDisplayLink?
    private let tickLock = NSLock()
    private var tickPending = false
    private var bag = Set<AnyCancellable>()
    private var frameTimes: [CFTimeInterval] = []

    static let projectType = UTType(exportedAs: "app.beamstage.project", conformingTo: .json)

    init?(device: MTLDevice) {
        self.device = device
        library = MediaLibrary(device: device)
        guard let r = Renderer(device: device, library: library) else { return nil }
        renderer = r
        super.init()
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        editor = EditorView(renderer: renderer, model: model)
        remote = RemoteServer(model: model)
        if UserDefaults.standard.bool(forKey: "remoteOn") { setRemote(true) }
        output = OutputController(renderer: renderer, model: model)
        buildMenu()

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Beamstage 4"
        w.contentView = NSHostingView(rootView: RootView(model: model, editor: editor))
        w.setFrameAutosaveName("BeamstageMain")
        if !w.setFrameUsingName("BeamstageMain") { w.center() }
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        mainWindow = w

        loadAutosave()
        model.$project
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.writeAutosave() }
            .store(in: &bag)
        model.$projectURL
            .sink { [weak self] u in self?.mainWindow?.title = u.map { "Beamstage 4 — \($0.deletingPathExtension().lastPathComponent)" } ?? "Beamstage 4" }
            .store(in: &bag)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handleKey(e) ?? e }
        NSApp.activate(ignoringOtherApps: true)
        startDisplayLink()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === mainWindow { NSApp.terminate(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let displayLink { CVDisplayLinkStop(displayLink) }
        writeAutosave()
        remote.stop()
        renderer.shutdown(project: model.project)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let u = URL(fileURLWithPath: filename)
        if u.pathExtension.lowercased() == "beamstage" { openProject(at: u) } else { model.addMedia([u]) }
        return true
    }

    // MARK: Render loop

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else {
            // No display link (headless?): fall back to a timer.
            let t = Timer(timeInterval: 1 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            return
        }
        CVDisplayLinkSetOutputHandler(displayLink) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            self.tickLock.lock()
            let skip = self.tickPending
            self.tickPending = true
            self.tickLock.unlock()
            if !skip {
                DispatchQueue.main.async {
                    self.tick()
                    self.tickLock.lock(); self.tickPending = false; self.tickLock.unlock()
                }
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(displayLink)
    }

    func tick() {
        let now = CACurrentMediaTime()
        if library.sync(model.project.media) || model.missingMedia != library.missing {
            model.missingMedia = library.missing
        }
        library.update(now: now, playing: model.playing)
        renderer.renderFrame(.init(project: model.project, selectedSurface: model.selectedSurfaceID,
                                   projectorBlackout: model.projectorBlackout, laserBlackout: model.laserBlackout,
                                   needLaserPreview: model.editorMode == .laser,
                                   test: TestState(test: model.laserTest, active: model.laserPoint,
                                                   projectorVisible: !model.blinkProjector || Int(now * 2) % 2 == 0)), now: now)
        let lc = renderer.laserServer?.hasClients ?? false
        let oc = renderer.outputServer?.hasClients ?? false
        if lc != model.laserClients {
            model.laserClients = lc
            NSLog("Beamstage: laser feed %@", lc ? "client connected" : "client disconnected")
        }
        if oc != model.outputClients {
            model.outputClients = oc
            NSLog("Beamstage: output feed %@", oc ? "client connected" : "client disconnected")
        }
        editor.render()
        output.view?.render()
    }

    // MARK: Keys

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        // Leave typing in text fields alone.
        if let r = NSApp.keyWindow?.firstResponder, r is NSText { return e }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty { return e }
        let shift = e.modifierFlags.contains(.shift)
        let step = shift ? 10.0 : 1.0
        switch e.keyCode {
        case 53: // Esc
            model.laserBlackout = true
            if model.isCalibrating { model.cancelCalibration() }
            output.releaseControlScreen(mainWindow)
            return nil
        case 49: model.playing.toggle(); return nil          // Space
        case 36, 76:                                          // Return / Enter
            if model.isCalibrating { model.stepCalibration(shift ? -1 : 1); return nil }
            return e
        case 123: model.nudge(V2(-step, 0)); return nil       // Left
        case 124: model.nudge(V2(step, 0)); return nil        // Right
        case 126: model.nudge(V2(0, -step)); return nil       // Up
        case 125: model.nudge(V2(0, step)); return nil        // Down
        case 48: model.cyclePoint(shift ? -1 : 1); return nil // Tab
        case 51, 117:                                         // Delete
            if model.selectedMaskIndex != nil, model.selectedPoint != nil { model.removeMaskPoint() }
            else if model.selection != .none { model.deleteSelected() }
            return nil
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "g": model.showGuides.toggle(); return nil
        case "b": model.projectorBlackout.toggle(); return nil
        case "f": if output.window != nil { output.toggleFullscreen() }; return nil
        case "t":   // cycle laser tests
            let all = LaserTest.allCases.filter { $0 != .calibrate }
            let i = all.firstIndex(of: model.laserTest) ?? 0
            model.laserTest = all[(i + 1) % all.count]
            return nil
        default: return e
        }
    }

    // MARK: Files

    var autosaveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Beamstage 4", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("autosave.beamstage")
    }

    private func loadAutosave() {
        guard let d = try? Data(contentsOf: autosaveURL), let p = try? JSONDecoder().decode(Project.self, from: d) else {
            model.selection = model.project.surfaces.first.map { .surface($0.id) } ?? .none
            return
        }
        model.replaceProject(p, url: UserDefaults.standard.url(forKey: "lastProjectURL"))
    }

    private func writeAutosave() {
        let enc = JSONEncoder()
        if let d = try? enc.encode(model.project) { try? d.write(to: autosaveURL, options: .atomic) }
    }

    func openProject(at url: URL) {
        do {
            let p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            model.replaceProject(p, url: url)
            UserDefaults.standard.set(url, forKey: "lastProjectURL")
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            alert("Couldn't open \(url.lastPathComponent)", error.localizedDescription)
        }
    }

    private func save(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(model.project).write(to: url, options: .atomic)
            model.projectURL = url
            UserDefaults.standard.set(url, forKey: "lastProjectURL")
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            alert("Couldn't save", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    func addMediaPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .gif, .image]
        if p.runModal() == .OK { model.addMedia(p.urls) }
    }

    func relinkPanel(_ id: UUID) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .gif, .image]
        p.message = "Find the file for “\(model.project.media.first { $0.id == id }?.name ?? "")”"
        if p.runModal() == .OK, let u = p.url { model.relinkMedia(id, to: u) }
    }

    // MARK: Menu actions

    @objc func newProject(_ sender: Any?) {
        model.replaceProject(.starter(), url: nil)
        UserDefaults.standard.removeObject(forKey: "lastProjectURL")
    }

    @objc func openDocument(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [AppController.projectType, .json]
        if p.runModal() == .OK, let u = p.url { openProject(at: u) }
    }

    @objc func saveDocument(_ sender: Any?) {
        if let u = model.projectURL { save(to: u) } else { saveDocumentAs(sender) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let p = NSSavePanel()
        p.allowedContentTypes = [AppController.projectType]
        p.nameFieldStringValue = model.projectURL?.lastPathComponent ?? "Untitled.beamstage"
        if p.runModal() == .OK, var u = p.url {
            if u.pathExtension != "beamstage" { u.appendPathExtension("beamstage") }
            save(to: u)
        }
    }

    @objc func addMedia(_ sender: Any?) { addMediaPanel() }
    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func openOutput(_ sender: Any?) {
        let target = NSScreen.screens.first { $0 != mainWindow?.screen } ?? NSScreen.main
        output.open(on: target)
    }
    @objc func toggleOutputFullscreen(_ sender: Any?) { output.toggleFullscreen() }
    @objc func toggleGuides(_ sender: Any?) { model.showGuides.toggle() }
    @objc func toggleBlackout(_ sender: Any?) { model.projectorBlackout.toggle() }
    @objc func blankLaser(_ sender: Any?) { model.laserBlackout = true }
    @objc func resumeLaser(_ sender: Any?) { model.laserBlackout = false }
    @objc func togglePlay(_ sender: Any?) { model.playing.toggle() }
    @objc func editLaser(_ sender: Any?) { model.editorMode = model.editorMode == .laser ? .projector : .laser }
    @objc func startCalibration(_ sender: Any?) { beginCalibration() }

    func setRemote(_ on: Bool) {
        if on {
            do { try remote.start(); model.remoteError = nil }
            catch { model.remoteError = "Couldn't start the phone remote: \(error.localizedDescription)" }
        } else {
            remote.stop()
        }
        model.remoteOn = remote.isRunning
        UserDefaults.standard.set(remote.isRunning, forKey: "remoteOn")
    }

    /// Starts calibration with the output on the projector, where the steps are shown.
    func beginCalibration() {
        ensureOutput()
        model.startCalibration()
    }

    func beginCheck() {
        ensureOutput()
        model.startCheck()
    }

    private func ensureOutput() {
        if output.window == nil {
            let projector = NSScreen.screens.first { $0 != mainWindow?.screen }
            output.open(on: projector ?? NSScreen.main)
        }
        output.window?.makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return model.canUndo
        case #selector(redo(_:)): return model.canRedo
        case #selector(toggleOutputFullscreen(_:)): return output.window != nil
        case #selector(toggleGuides(_:)): item.state = model.showGuides ? .on : .off; return true
        case #selector(toggleBlackout(_:)): item.state = model.projectorBlackout ? .on : .off; return true
        case #selector(resumeLaser(_:)): return model.laserBlackout
        default: return true
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
        }
        func item(_ t: String, _ a: Selector, _ k: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            i.target = target ?? self
            return i
        }
        menu("Beamstage", [
            item("About Beamstage 4", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
            .separator(),
            item("Hide Beamstage", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            .separator(),
            item("Quit Beamstage", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])
        menu("File", [
            item("New Project", #selector(newProject(_:)), "n"),
            item("Open…", #selector(openDocument(_:)), "o"),
            .separator(),
            item("Save", #selector(saveDocument(_:)), "s"),
            item("Save As…", #selector(saveDocumentAs(_:)), "s", [.command, .shift]),
            .separator(),
            item("Add Media…", #selector(addMedia(_:)), "i"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", target: nil),
        ])
        // Text editing actions go to the first responder so text fields keep working.
        let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let all = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu("Edit", [
            item("Undo", #selector(undo(_:)), "z"),
            item("Redo", #selector(redo(_:)), "z", [.command, .shift]),
            .separator(), cut, copy, paste, all,
        ])
        menu("Show", [
            item("Play / Pause", #selector(togglePlay(_:)), "p"),
            item("Edit Laser Alignment", #selector(editLaser(_:)), "l"),
            item("Calibrate Laser…", #selector(startCalibration(_:)), "k"),
            .separator(),
            item("Open Output Window", #selector(openOutput(_:)), "o", [.command, .shift]),
            item("Toggle Output Fullscreen", #selector(toggleOutputFullscreen(_:)), "f", [.command, .control]),
            item("Show Guides on Projector", #selector(toggleGuides(_:)), "g", [.command, .shift]),
            item("Black Out Projector", #selector(toggleBlackout(_:)), "b", [.command, .shift]),
            .separator(),
            item("Blank Laser Feed", #selector(blankLaser(_:)), "."),
            item("Resume Laser Feed", #selector(resumeLaser(_:)), "r", [.command, .shift]),
        ])
        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil))
        let winTop = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        winTop.submenu = win
        main.addItem(winTop)
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}
