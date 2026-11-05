import AppKit
import CoreImage
import Foundation
import Network

/// A tiny HTTP server for the phone remote. Every request must carry the pairing key
/// from the QR code, so other devices on the network can't drive the show.
final class RemoteServer {
    static let port: UInt16 = 4790

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "beamstage.remote")
    private weak var model: AppModel?
    private let page: Data
    let key: String

    var isRunning: Bool { listener != nil }

    init(model: AppModel) {
        self.model = model
        let saved = UserDefaults.standard.string(forKey: "remoteKey")
        key = saved ?? String((0..<12).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
        UserDefaults.standard.set(key, forKey: "remoteKey")
        if let url = Bundle.main.url(forResource: "remote", withExtension: "html"), let d = try? Data(contentsOf: url) {
            page = d
        } else {
            page = Data("<h1>Beamstage remote page missing from the app bundle</h1>".utf8)
        }
    }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: RemoteServer.port)!)
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st {
                NSLog("Beamstage remote: listener failed: \(e)")
                DispatchQueue.main.async { self?.stop() }
            }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Addresses a phone on the same network can reach.
    var urls: [String] {
        RemoteServer.localIPv4().map { "http://\($0):\(RemoteServer.port)/?k=\(key)" }
    }

    // MARK: Connections

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 1_000_000 || err != nil { c.cancel(); return }
            guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if done { c.cancel() } else { self.receive(c, buffer: buf) }
                return
            }
            let head = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ").map(String.init) ?? []
            var length = 0
            for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
                length = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            let body = buf[headEnd.upperBound...]
            if body.count < length && !done { self.receive(c, buffer: buf); return }
            let method = parts.count > 0 ? parts[0] : "GET"
            let target = parts.count > 1 ? parts[1] : "/"
            let (status, type, out) = self.route(method: method, target: target, body: Data(body.prefix(length)))
            self.respond(c, status: status, type: type, body: out)
        }
    }

    private func respond(_ c: NWConnection, status: String, type: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        var d = Data(head.utf8)
        d.append(body)
        c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
    }

    private func route(method: String, target: String, body: Data) -> (String, String, Data) {
        let comps = URLComponents(string: target)
        let path = comps?.path ?? "/"
        let k = comps?.queryItems?.first { $0.name == "k" }?.value
        if path == "/" || path == "/index.html" {
            // The page itself holds no secrets; it reads the key from its own URL.
            return ("200 OK", "text/html; charset=utf-8", page)
        }
        guard k == key else { return ("403 Forbidden", "application/json", Data(#"{"error":"bad key"}"#.utf8)) }
        switch (method, path) {
        case ("GET", "/state"):
            return ("200 OK", "application/json", DispatchQueue.main.sync { self.stateJSON() })
        case ("POST", "/action"):
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            return ("200 OK", "application/json", DispatchQueue.main.sync { () -> Data in
                self.perform(obj)
                return self.stateJSON()
            })
        default:
            return ("404 Not Found", "application/json", Data(#"{"error":"not found"}"#.utf8))
        }
    }

    // MARK: State and actions (main thread)

    private func stateJSON() -> Data {
        guard let m = model else { return Data("{}".utf8) }
        let cal = m.project.laser.calibration
        let k = m.laserPoint ?? 0
        let c = Palette.calib(k)
        let hex = String(format: "#%02x%02x%02x", Int(c.x * 255), Int(c.y * 255), Int(c.z * 255))
        let st: [String: Any] = [
            "playing": m.playing,
            "projectorBlackout": m.projectorBlackout,
            "laserBlackout": m.laserBlackout,
            "laserClients": m.laserClients,
            "showGuides": m.showGuides,
            "outputOpen": m.outputOpen,
            "laserMode": m.project.laser.mode.rawValue,
            "laserModes": LaserMode.allCases.map { ["id": $0.rawValue, "label": $0.label] },
            "laserTest": m.laserTest.rawValue,
            "blink": m.blinkProjector,
            "calib": [
                "session": m.calibSession,
                "calibrating": m.isCalibrating,
                "point": k, "count": cal.count, "color": hex,
                "grid": cal.cols + 1,
            ],
            "project": m.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled",
        ]
        return (try? JSONSerialization.data(withJSONObject: st)) ?? Data("{}".utf8)
    }

    private func perform(_ o: [String: Any]) {
        guard let m = model, let a = o["a"] as? String else { return }
        let app = AppController.shared!
        switch a {
        case "blank": m.laserBlackout = true; if m.isCalibrating { m.cancelCalibration() }
        case "resume": m.laserBlackout = false
        case "play": m.playing.toggle()
        case "restart": app.library.restartAll()
        case "blackout": m.projectorBlackout.toggle()
        case "guides": m.showGuides.toggle()
        case "calibStart": app.beginCalibration()
        case "check": app.beginCheck()
        case "next": if m.isCalibrating { m.stepCalibration(1) }
        case "back": if m.isCalibrating { m.stepCalibration(-1) }
        case "cancel": m.cancelCalibration()
        case "done": m.finishCalibration()
        case "redo": m.redoCalibration()
        case "blink": m.blinkProjector.toggle()
        case "move":
            // Trackpad and arrow moves, in projector pixels.
            let dx = (o["dx"] as? Double) ?? 0, dy = (o["dy"] as? Double) ?? 0
            if m.isCalibrating && dx.isFinite && dy.isFinite && abs(dx) < 2000 && abs(dy) < 2000 { m.nudge(V2(dx, dy)) }
        case "test":
            if let v = o["v"] as? String, let t = LaserTest(rawValue: v), t != .calibrate, !m.isCalibrating { m.laserTest = t }
        case "mode":
            if let v = o["v"] as? String, let mode = LaserMode(rawValue: v) { m.edit { $0.laser.mode = mode } }
        case "grid":
            if let n = o["v"] as? Int, !m.calibSession { m.setCalibrationGrid(n) }
        default: break
        }
    }

    // MARK: Helpers

    static func localIPv4() -> [String] {
        var out: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { out.append((String(cString: ifa.ifa_name), ip)) }
            }
        }
        // Wi-Fi / Ethernet first.
        return out.sorted { a, b in a.0.hasPrefix("en") && !b.0.hasPrefix("en") }.map(\.1)
    }

    static func qrImage(_ text: String, size: CGFloat = 220) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = f.outputImage else { return nil }
        let s = size / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
