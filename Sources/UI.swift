import AppKit
import SwiftUI

struct EditorHost: NSViewRepresentable {
    let view: EditorView
    func makeNSView(context: Context) -> EditorView { view }
    func updateNSView(_ nsView: EditorView, context: Context) {}
}

struct RootView: View {
    @ObservedObject var model: AppModel
    let editor: EditorView

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TopBar(model: model)
                Divider()
                ZStack(alignment: .bottomLeading) {
                    EditorHost(view: editor)
                    HintBar(model: model).padding(10)
                }
                .overlay(alignment: .top) {
                    if model.calibSession { CalibrationPopup(model: model, scale: 1).padding(10) }
                    else if model.laserTest != .off { TestBanner(model: model).padding(10) }
                }
            }
            Divider()
            Sidebar(model: model).frame(width: 340)
        }
        .frame(minWidth: 980, minHeight: 600)
    }
}

struct TopBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { model.playing.toggle() }) {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .help("Play or pause (Space)")
            Button(action: { AppController.shared.library.restartAll() }) { Image(systemName: "backward.end.fill") }
                .help("Restart all clips")

            Picker("", selection: $model.editorMode) {
                Text("Projector").tag(EditorMode.projector)
                Text("Laser").tag(EditorMode.laser)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            .help("Edit the projection, or line up the laser feed")

            Spacer()

            StatusPill(on: model.laserClients, onText: "Laser app connected", offText: "Laser feed: waiting")
            if model.laserBlackout {
                Button("Laser feed blanked — resume") { model.laserBlackout = false }
                    .foregroundColor(.orange)
            } else {
                Button(action: { model.laserBlackout = true }) { Label("Blank laser", systemImage: "stop.circle.fill") }
                    .help("Send black to the laser feed (Esc)")
            }
            Toggle("Blackout", isOn: $model.projectorBlackout).toggleStyle(.button).help("Black out the projector (B)")
            Menu {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, s in
                    Button("Open on \(s.localizedName)") { AppController.shared.output.open(on: s) }
                }
                if model.outputOpen {
                    Divider()
                    Button("Toggle fullscreen") { AppController.shared.output.toggleFullscreen() }
                    Button("Close output") { AppController.shared.output.close() }
                }
            } label: {
                Label(model.outputOpen ? "Output open" : "Output window", systemImage: "rectangle.on.rectangle")
            }
            .frame(width: 150)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct StatusPill: View {
    let on: Bool
    let onText: String
    let offText: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(on ? onText : offText).font(.caption).foregroundColor(.secondary)
        }
    }
}

struct HintBar: View {
    @ObservedObject var model: AppModel
    var text: String {
        if model.isCalibrating {
            return "Click where you see the laser's circled cross, or drag it. Arrows fine-tune (Shift ×10). Return = next, Esc = cancel."
        }
        if model.editorMode == .laser {
            return "Laser view: each handle is where a projector point lands in the laser feed. Drag or use the arrows (Shift ×10); Tab picks a point."
        }
        switch model.selection {
        case .mask: return "Drag points or the whole mask. Double-click to add a point, Option-click a point to remove it."
        case .surface: return "Drag corners or the surface. Arrows nudge (Shift ×10). Tab cycles points."
        case .none: return "Drop videos, GIFs or images here. Click a surface to select it."
        }
    }
    var body: some View {
        Text(text).font(.caption).foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.55)).cornerRadius(5)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Map").tag(0); Text("Media").tag(1); Text("Laser").tag(2); Text("Output").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case 0: MapTab(model: model)
                    case 1: MediaTab(model: model)
                    case 2: LaserTab(model: model)
                    default: OutputTab(model: model)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: model.editorMode) { m in if m == .laser { tab = 2 } }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundColor(.secondary) }
}

struct Row<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.04))
            .cornerRadius(5)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var body: some View {
        HStack {
            Text(title).frame(width: 78, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value)).monospacedDigit().frame(width: 44, alignment: .trailing).foregroundColor(.secondary)
        }
    }
}

struct MapTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SectionTitle("Surfaces")
        VStack(spacing: 4) {
            ForEach(model.project.surfaces) { s in
                Row(selected: model.selection == .surface(s.id), action: { model.selection = .surface(s.id); model.selectedPoint = nil }) {
                    Image(systemName: s.visible ? "square.on.square" : "eye.slash").foregroundColor(.secondary)
                    Text(s.name).lineLimit(1)
                    Spacer()
                    Text(mediaName(s.mediaID)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    if s.toLaser { Image(systemName: "rays").foregroundColor(.green).help("Sent to the laser") }
                }
            }
        }
        HStack {
            Button("Add surface") { model.addSurface() }
            Button("Duplicate") { model.duplicateSelected() }.disabled(model.selection == .none)
            Spacer()
            Button(action: { model.moveSelected(-1) }) { Image(systemName: "arrow.up") }.help("Draw earlier (further back)")
            Button(action: { model.moveSelected(1) }) { Image(systemName: "arrow.down") }.help("Draw later (in front)")
            Button(action: { model.deleteSelected() }) { Image(systemName: "trash") }.disabled(model.selection == .none)
        }
        .controlSize(.small)

        if let i = model.selectedSurfaceIndex {
            SurfaceInspector(model: model, id: model.project.surfaces[i].id).id(model.project.surfaces[i].id)
        }

        Divider()
        SectionTitle("Masks")
        Text("Black shapes drawn over everything, for windows, doors and anything that shouldn't be lit.")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 4) {
            ForEach(model.project.masks) { m in
                Row(selected: model.selection == .mask(m.id), action: { model.selection = .mask(m.id); model.selectedPoint = nil }) {
                    Image(systemName: m.visible ? "square.dashed.inset.filled" : "eye.slash").foregroundColor(.pink)
                    Text(m.name)
                    Spacer()
                    Text("\(m.points.count) points").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        HStack {
            Button("Add mask") { model.addMask() }
            if model.selectedMaskIndex != nil {
                Button("Add point") { model.addMaskPoint() }
                Button("Remove point") { model.removeMaskPoint() }.disabled(model.selectedPoint == nil)
            }
        }
        .controlSize(.small)
        if let i = model.selectedMaskIndex {
            let id = model.project.masks[i].id
            TextField("Name", text: model.maskBinding(id, \.name, fallback: ""))
            Toggle("Visible", isOn: model.maskBinding(id, \.visible, fallback: true))
        }
    }

    func mediaName(_ id: UUID?) -> String {
        guard let id else { return "No media" }
        return model.project.allMedia.first { $0.id == id }?.name ?? "Missing"
    }
}

struct SurfaceInspector: View {
    @ObservedObject var model: AppModel
    let id: UUID

    var surface: Surface? { model.project.surfaces.first { $0.id == id } }

    var body: some View {
        if let s = surface {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: model.surfaceBinding(id, \.name, fallback: ""))
                Picker("Media", selection: model.surfaceBinding(id, \.mediaID, fallback: nil)) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.project.allMedia) { m in Text(m.name).tag(Optional(m.id)) }
                }
                HStack {
                    Toggle("Visible", isOn: model.surfaceBinding(id, \.visible, fallback: true))
                    Spacer()
                    Toggle("Send to laser", isOn: model.surfaceBinding(id, \.toLaser, fallback: true))
                }
                LabeledSlider(title: "Opacity", value: model.surfaceBinding(id, \.opacity, fallback: 1), range: 0...1)
                LabeledSlider(title: "Brightness", value: model.surfaceBinding(id, \.brightness, fallback: 1), range: 0...2)
                LabeledSlider(title: "Soft edge", value: model.surfaceBinding(id, \.feather, fallback: 0), range: 0...0.5)

                SectionTitle("Bend grid")
                HStack {
                    Stepper("Columns \(s.cols)", onIncrement: { model.setGrid(cols: s.cols + 1, rows: s.rows) },
                            onDecrement: { model.setGrid(cols: s.cols - 1, rows: s.rows) })
                    Spacer()
                    Stepper("Rows \(s.rows)", onIncrement: { model.setGrid(cols: s.cols, rows: s.rows + 1) },
                            onDecrement: { model.setGrid(cols: s.cols, rows: s.rows - 1) })
                }
                Text("Add columns or rows to bend the picture around curved surfaces.")
                    .font(.caption).foregroundColor(.secondary)

                SectionTitle("Crop video")
                LabeledSlider(title: "Left", value: cropBinding(\.x), range: 0...0.99)
                LabeledSlider(title: "Top", value: cropBinding(\.y), range: 0...0.99)
                LabeledSlider(title: "Width", value: cropBinding(\.w), range: 0.01...1)
                LabeledSlider(title: "Height", value: cropBinding(\.h), range: 0.01...1)

                HStack {
                    Button("Fill output") { model.fillOutput() }
                    Button("Flatten grid") { model.flattenGrid() }.disabled(s.cols * s.rows == 1)
                    Button("Reset crop") { model.surfaceBinding(id, \.crop, fallback: Crop()).wrappedValue = Crop() }
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)
        }
    }

    func cropBinding(_ kp: WritableKeyPath<Crop, Double>) -> Binding<Double> {
        let b = model.surfaceBinding(id, \.crop, fallback: Crop())
        return Binding(get: { b.wrappedValue[keyPath: kp] }, set: { v in
            var c = b.wrappedValue
            c[keyPath: kp] = v
            c.w = min(c.w, 1 - c.x); c.h = min(c.h, 1 - c.y)
            c.w = max(c.w, 0.01); c.h = max(c.h, 0.01)
            b.wrappedValue = c
        })
    }
}

struct MediaTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SectionTitle("Media")
        Text("MP4, MOV (including ProRes and HEVC), GIF, PNG and JPEG. Files stay where they are; the project remembers their location.")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        Button("Add media…") { AppController.shared.addMediaPanel() }
        VStack(spacing: 4) {
            ForEach(model.project.media) { m in
                Row(selected: false, action: {}) {
                    Image(systemName: icon(m)).foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name).lineLimit(1)
                        if model.missingMedia.contains(m.id) {
                            Text("File not found").font(.caption).foregroundColor(.orange)
                        }
                    }
                    Spacer()
                    if model.missingMedia.contains(m.id) {
                        Button("Relink…") { AppController.shared.relinkPanel(m.id) }.controlSize(.small)
                    }
                    if isVideo(m) {
                        Button(action: { toggleMute(m.id) }) {
                            Image(systemName: m.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .buttonStyle(.borderless).help("Mute")
                    }
                    Button(action: { model.removeMedia(m.id) }) { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Remove from project")
                }
            }
        }
        if model.project.media.isEmpty {
            Text("No media yet. Drop files onto the editor.").foregroundColor(.secondary)
        }
        Divider()
        SectionTitle("Built in")
        Text("Test pattern — grid, circles and coloured corners for lining up surfaces.\nSolid white — for blending and checking coverage.")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    func isVideo(_ m: MediaRef) -> Bool { ["mp4", "mov", "m4v"].contains((m.path as NSString).pathExtension.lowercased()) }
    func icon(_ m: MediaRef) -> String { isVideo(m) ? "film" : "photo" }
    func toggleMute(_ id: UUID) {
        guard let i = model.project.media.firstIndex(where: { $0.id == id }) else { return }
        model.edit { $0.media[i].muted.toggle() }
    }
}

struct LaserTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SectionTitle("Syphon laser feed")
        HStack {
            StatusPill(on: model.laserClients, onText: "An app is connected", offText: "Waiting for an app")
            Spacer()
        }
        Text("Beamstage publishes **Beamstage Laser** over Syphon. In LaserOS, open Cast and choose it as the source. Laser power and safety are controlled in LaserOS.")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

        if model.laserBlackout {
            Button("Resume laser feed") { model.laserBlackout = false }
            Text("The feed is sending black. Esc blanks it at any time.").font(.caption).foregroundColor(.orange)
        } else {
            Button("Blank laser feed (Esc)") { model.laserBlackout = true }
        }

        Divider()
        SectionTitle("What to send")
        Picker("", selection: model.projectBinding(\.laser.mode)) {
            ForEach(LaserMode.allCases) { m in Text(m.label).tag(m) }
        }
        .pickerStyle(.radioGroup).labelsHidden()
        Text(model.project.laser.mode.help).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        if model.project.laser.mode == .outlines || model.project.laser.mode == .align || model.laserTest != .off {
            LabeledSlider(title: "Line width", value: model.projectBinding(\.laser.lineWidth), range: 1...12,
                          format: { String(format: "%.0f px", $0) })
        }

        Divider()
        CalibrationPanel(model: model)

        Divider()
        SectionTitle("Feed format")
        Picker("Size", selection: sizeBinding) {
            Text("1920 × 1080").tag("1920x1080")
            Text("1280 × 720").tag("1280x720")
            Text("1024 × 1024").tag("1024x1024")
            Text("640 × 360").tag("640x360")
            Text("512 × 512").tag("512x512")
            if !presets.contains(sizeBinding.wrappedValue) {
                Text("\(model.project.laser.width) × \(model.project.laser.height)").tag(sizeBinding.wrappedValue)
            }
        }
        Picker("Frame rate", selection: model.projectBinding(\.laser.fps)) {
            ForEach([60, 50, 30, 25, 24, 15], id: \.self) { Text("\($0) fps").tag($0) }
        }
        Text("Frames go out only while an app is connected. A second server, **Beamstage Output**, carries the clean projector picture for other Syphon apps.")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private let presets = ["1920x1080", "1280x720", "1024x1024", "640x360", "512x512"]

    var sizeBinding: Binding<String> {
        Binding(get: { "\(model.project.laser.width)x\(model.project.laser.height)" }, set: { v in
            let parts = v.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { return }
            model.edit { $0.laser.width = parts[0]; $0.laser.height = parts[1] }
        })
    }
}

struct OutputTab: View {
    @ObservedObject var model: AppModel
    @State private var w = ""
    @State private var h = ""

    var body: some View {
        SectionTitle("Projector")
        Text("Set the projector as an extended display (not mirrored), at its native resolution. Keep “Displays have separate Spaces” on.")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, s in
            HStack {
                VStack(alignment: .leading) {
                    Text(s.localizedName)
                    Text("\(Int(s.frame.width * s.backingScaleFactor)) × \(Int(s.frame.height * s.backingScaleFactor))")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("Open here") { AppController.shared.output.open(on: s) }.controlSize(.small)
                Button("Match") { matchScreen(s) }.controlSize(.small).help("Use this display's resolution for the output")
            }
        }
        if model.outputOpen {
            HStack {
                Button("Toggle fullscreen") { AppController.shared.output.toggleFullscreen() }
                Button("Close output") { AppController.shared.output.close() }
            }
            .controlSize(.small)
        }
        Text("Double-click the output window to switch fullscreen.").font(.caption).foregroundColor(.secondary)

        Divider()
        SectionTitle("Output resolution")
        HStack {
            TextField("Width", text: $w, onCommit: apply).frame(width: 70)
            Text("×")
            TextField("Height", text: $h, onCommit: apply).frame(width: 70)
            Button("Set", action: apply).controlSize(.small)
        }
        .onAppear { w = "\(model.project.outputWidth)"; h = "\(model.project.outputHeight)" }
        Text("Mapping is stored relative to the frame, so changing resolution keeps your corners in place.")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

        Divider()
        PhoneRemoteSection(model: model)

        Divider()
        SectionTitle("While mapping")
        Toggle("Show guides on the projector (G)", isOn: $model.showGuides)
        Toggle("Black out the projector (B)", isOn: $model.projectorBlackout)
        Text("Guides are drawn only on the projector and in the editor. They never go out over Syphon.")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    func apply() {
        guard let wi = Int(w), let hi = Int(h), (16...8192).contains(wi), (16...8192).contains(hi) else { NSSound.beep(); return }
        model.edit { $0.outputWidth = wi; $0.outputHeight = hi }
    }

    func matchScreen(_ s: NSScreen) {
        let wi = Int(s.frame.width * s.backingScaleFactor), hi = Int(s.frame.height * s.backingScaleFactor)
        w = "\(wi)"; h = "\(hi)"
        model.edit { $0.outputWidth = wi; $0.outputHeight = hi }
    }
}

// MARK: - Calibration and tests

struct CalibrationPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SectionTitle("Calibrate the laser")
        Text("Lines the laser up with the projection. The steps appear on the projector, so you can follow them while looking at the wall.")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

        if model.calibSession {
            Text(model.isCalibrating ? "Calibrating… follow the steps on the projector." : "Checking… choose Done or Redo on the projector.")
                .foregroundColor(.accentColor)
            Button("Cancel calibration") { model.cancelCalibration() }
        } else {
            HStack {
                Button(action: { AppController.shared.beginCalibration() }) {
                    Label("Calibrate laser", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Button("Check") { AppController.shared.beginCheck() }.controlSize(.large)
                    .help("Show the test grid on both, without changing anything")
            }
        }

        DisclosureGroup("More options") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Points", selection: Binding(get: { model.project.laser.calibration.cols + 1 },
                                                    set: { model.setCalibrationGrid($0) })) {
                    Text("4").tag(2); Text("9").tag(3); Text("16").tag(4); Text("25").tag(5)
                }
                .pickerStyle(.segmented)
                Text("4 points fix position, size and keystone. Use more if the laser's lines curve near the edges.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Toggle("Flip left/right", isOn: model.projectBinding(\.laser.flipX))
                    Toggle("Flip up/down", isOn: model.projectBinding(\.laser.flipY))
                }
                HStack {
                    Button("Reset calibration") { model.resetLaserAlignment() }
                    Button("Edit points by hand") { model.editorMode = .laser }
                }
                .controlSize(.small)
            }
            .padding(.top, 6)
        }
        .disabled(model.calibSession)
    }
}

/// Step-by-step calibration panel. Shown over the projector output and the editor.
struct CalibrationPopup: View {
    @ObservedObject var model: AppModel
    let scale: CGFloat

    private func f(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: size * scale, weight: w) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            if model.isCalibrating { pointStep } else { checkStep }
            warnings
        }
        .padding(14 * scale)
        .frame(width: 460 * scale, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12 * scale).fill(Color(white: 0.1).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 12 * scale).stroke(Color.white.opacity(0.2)))
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var pointStep: some View {
        let n = model.project.laser.calibration.count
        let k = model.laserPoint ?? 0
        HStack(spacing: 10 * scale) {
            Circle().fill(Color(rgba: Palette.calib(k))).frame(width: 16 * scale, height: 16 * scale)
            Text("Laser calibration").font(f(17, .semibold))
            Spacer()
            Text("Point \(k + 1) of \(n)").font(f(14)).foregroundColor(.white.opacity(0.7))
        }
        HStack(spacing: 4 * scale) {
            ForEach(0..<n, id: \.self) { i in
                Capsule().fill(i < k ? Color.green : (i == k ? Color(rgba: Palette.calib(k)) : Color.white.opacity(0.2)))
                    .frame(height: 4 * scale)
            }
        }
        Text("Find the laser's circled cross on the wall, then **click on it**. The laser jumps to the projector's circled cross.")
            .font(f(14)).fixedSize(horizontal: false, vertical: true)
        Text("Not quite there? Click it again, drag it, or use the arrow keys.")
            .font(f(12)).foregroundColor(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8 * scale) {
            Button("Cancel") { model.cancelCalibration() }
            Spacer()
            Button("Back") { model.stepCalibration(-1) }.disabled(k == 0)
            Button(k + 1 >= n ? "Check result" : "Next point") { model.stepCalibration(1) }
                .keyboardShortcut(.defaultAction)
        }
        .font(f(13))
        .controlSize(scale > 1.2 ? .large : .regular)
    }

    @ViewBuilder private var checkStep: some View {
        HStack {
            Image(systemName: "checkmark.seal").font(f(17))
            Text("Check the result").font(f(17, .semibold))
            Spacer()
        }
        Text("The laser should sit on the cyan lines everywhere. Where you see two lines, it's off.")
            .font(f(14)).fixedSize(horizontal: false, vertical: true)
        HStack {
            Picker("", selection: Binding(get: { model.laserTest == .outlines ? LaserTest.outlines : .grid },
                                          set: { model.laserTest = $0 })) {
                Text("Grid").tag(LaserTest.grid)
                Text("My surfaces").tag(LaserTest.outlines)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220 * scale)
            Toggle("Blink", isOn: $model.blinkProjector).help("Blink the cyan lines to tell them from the laser")
        }
        .font(f(13))
        HStack(spacing: 8 * scale) {
            Button("Cancel") { model.cancelCalibration() }
            Spacer()
            Button("Redo points") { model.redoCalibration() }
            Button("Done") { model.finishCalibration() }.keyboardShortcut(.defaultAction)
        }
        .font(f(13))
        .controlSize(scale > 1.2 ? .large : .regular)
    }

    @ViewBuilder private var warnings: some View {
        if model.laserBlackout {
            HStack {
                Label("The laser feed is blanked.", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Spacer()
                Button("Resume laser") { model.laserBlackout = false }
            }
            .font(f(13))
        } else if !model.laserClients {
            Label("LaserOS isn't connected. In LaserOS, open Cast and choose Beamstage Laser.", systemImage: "bolt.horizontal.circle")
                .font(f(12)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TestBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
            Text("Laser test: \(model.laserTest.label). Cyan is the projector; the laser should sit on it.").font(.callout)
            Spacer(minLength: 8)
            Button("Recalibrate") { AppController.shared.beginCalibration() }
            Button("End test") { model.laserTest = .off }
        }
        .padding(10)
        .background(.regularMaterial)
        .cornerRadius(8)
        .frame(maxWidth: 640)
    }
}

extension Color {
    init(rgba c: RGBA) { self.init(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: Double(c.w)) }
}

// MARK: - Phone remote

struct PhoneRemoteSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SectionTitle("Phone remote")
        Text("Steer laser calibration, blank the laser and run the show from your phone. The phone must be on the same Wi-Fi as this Mac.")
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        Toggle("Turn on phone remote", isOn: Binding(get: { model.remoteOn }, set: { AppController.shared.setRemote($0) }))
        if let e = model.remoteError { Text(e).font(.caption).foregroundColor(.orange) }
        if model.remoteOn {
            let urls = AppController.shared.remote.urls
            if let u = urls.first {
                HStack(alignment: .top, spacing: 12) {
                    if let img = RemoteServer.qrImage(u) {
                        Image(nsImage: img).interpolation(.none).resizable().frame(width: 132, height: 132)
                            .padding(6).background(Color.white).cornerRadius(6)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scan with your phone's camera.").font(.caption)
                        Text(u).font(.caption2.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("Copy link") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
                ForEach(urls.dropFirst(), id: \.self) { Text($0).font(.caption2.monospaced()).textSelection(.enabled) }
                Text("The link has a private key, so only devices with it can connect. If macOS asks, allow incoming connections.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This Mac isn't on a network. Join the same Wi-Fi as your phone.").font(.caption).foregroundColor(.orange)
            }
        }
    }
}
