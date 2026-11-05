import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import QuartzCore

protocol MediaSource: AnyObject {
    var texture: MTLTexture? { get }
    func update(now: CFTimeInterval, playing: Bool)
    func setPlaying(_ playing: Bool)
    func restart()
    func setMuted(_ muted: Bool)
}

/// Creates a BGRA texture from a CGImage, optionally capping its longest side.
func makeTexture(device: MTLDevice, image: CGImage, maxSide: Int = 4096) -> MTLTexture? {
    var w = image.width, h = image.height
    let longest = max(w, h)
    if longest > maxSide {
        let s = Double(maxSide) / Double(longest)
        w = max(1, Int(Double(w) * s)); h = max(1, Int(Double(h) * s))
    }
    let bpr = w * 4
    var data = [UInt8](repeating: 0, count: bpr * h)
    let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let ok: Bool = data.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: cs, bitmapInfo: info) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = .shaderRead
    guard let t = device.makeTexture(descriptor: d) else { return nil }
    data.withUnsafeBytes { buf in
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: bpr)
    }
    return t
}

// MARK: - Video

final class VideoSource: MediaSource {
    private let player = AVPlayer()
    private let output: AVPlayerItemVideoOutput
    private var cache: CVMetalTextureCache?
    private var cvTexture: CVMetalTexture?
    private var endObserver: NSObjectProtocol?
    private(set) var texture: MTLTexture?
    private var wantsPlay = true

    init?(url: URL, device: MTLDevice) {
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else { return nil }
        let item = AVPlayerItem(url: url)
        item.add(output)
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            if self.wantsPlay { self.player.play() }
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.pause()
    }

    func update(now: CFTimeInterval, playing: Bool) {
        let t = output.itemTime(forHostTime: now)
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
              let cache else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cv: CVMetalTexture?
        if CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cv) == kCVReturnSuccess,
           let cv, let tex = CVMetalTextureGetTexture(cv) {
            cvTexture = cv
            texture = tex
        }
    }

    func setPlaying(_ playing: Bool) {
        wantsPlay = playing
        if playing { player.play() } else { player.pause() }
    }

    func restart() {
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        if wantsPlay { player.play() }
    }

    func setMuted(_ muted: Bool) { player.isMuted = muted }
}

// MARK: - GIF and stills

final class ImageSequenceSource: MediaSource {
    private var frames: [MTLTexture] = []
    private var ends: [Double] = []   // cumulative end time of each frame
    private var clock = 0.0
    private var last: CFTimeInterval = 0
    private(set) var texture: MTLTexture?

    init?(url: URL, device: MTLDevice) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(src), 2000)
        guard count > 0 else { return nil }
        // Keep big animations within memory by shrinking frames.
        let maxSide = count > 300 ? 1024 : (count > 60 ? 2048 : 4096)
        var total = 0.0
        for i in 0..<count {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil),
                  let tex = makeTexture(device: device, image: img, maxSide: maxSide) else { continue }
            var delay = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] {
                let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                    ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                    ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double)
                if let d { delay = d < 0.011 ? 0.1 : d }   // browsers treat ~0 delays as 100 ms
            }
            total += delay
            frames.append(tex); ends.append(total)
        }
        guard !frames.isEmpty else { return nil }
        texture = frames[0]
    }

    var frameCount: Int { frames.count }

    func update(now: CFTimeInterval, playing: Bool) {
        if last == 0 { last = now }
        if playing { clock += now - last }
        last = now
        guard frames.count > 1, let total = ends.last, total > 0 else { return }
        let t = clock.truncatingRemainder(dividingBy: total)
        var lo = 0, hi = ends.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        texture = frames[lo]
    }

    func setPlaying(_ playing: Bool) {}
    func restart() { clock = 0 }
    func setMuted(_ muted: Bool) {}
}

final class StaticSource: MediaSource {
    let texture: MTLTexture?
    init(texture: MTLTexture?) { self.texture = texture }
    func update(now: CFTimeInterval, playing: Bool) {}
    func setPlaying(_ playing: Bool) {}
    func restart() {}
    func setMuted(_ muted: Bool) {}
}

// MARK: - Library

final class MediaLibrary {
    static let testPatternID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let whiteID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!

    let device: MTLDevice
    private var sources: [UUID: MediaSource] = [:]
    private var loadedPaths: [UUID: String] = [:]
    private(set) var missing: Set<UUID> = []
    private var lastRefs: [MediaRef] = []
    private var playing = true

    init(device: MTLDevice) {
        self.device = device
        sources[MediaLibrary.testPatternID] = StaticSource(texture: MediaLibrary.makeTestPattern(device: device))
        sources[MediaLibrary.whiteID] = StaticSource(texture: MediaLibrary.makeSolid(device: device))
    }

    /// Loads, reloads and drops sources so they match the project's media list.
    /// Returns true if the set of missing files changed.
    @discardableResult
    func sync(_ refs: [MediaRef]) -> Bool {
        guard refs != lastRefs else { return false }
        lastRefs = refs
        let before = missing
        let ids = Set(refs.map(\.id))
        for id in Array(loadedPaths.keys) where !ids.contains(id) {
            sources[id] = nil; loadedPaths[id] = nil
        }
        missing = missing.intersection(ids)
        for r in refs where r.kind == .file {
            if loadedPaths[r.id] != r.path {
                loadedPaths[r.id] = r.path
                sources[r.id] = nil
                let url = URL(fileURLWithPath: r.path)
                if FileManager.default.fileExists(atPath: r.path), let s = MediaLibrary.load(url: url, device: device) {
                    s.setPlaying(playing)
                    sources[r.id] = s
                    missing.remove(r.id)
                } else {
                    missing.insert(r.id)
                }
            }
            sources[r.id]?.setMuted(r.muted)
        }
        return missing != before
    }

    static func load(url: URL, device: MTLDevice) -> MediaSource? {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return VideoSource(url: url, device: device)
        default: return ImageSequenceSource(url: url, device: device)
        }
    }

    func update(now: CFTimeInterval, playing: Bool) {
        if playing != self.playing {
            self.playing = playing
            for s in sources.values { s.setPlaying(playing) }
        }
        for s in sources.values { s.update(now: now, playing: playing) }
    }

    func restartAll() { for s in sources.values { s.restart() } }

    func texture(_ id: UUID?) -> MTLTexture? {
        guard let id else { return nil }
        return sources[id]?.texture
    }

    func source(_ id: UUID) -> MediaSource? { sources[id] }

    // MARK: Built-ins

    static func makeSolid(device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        let px = [UInt8](repeating: 255, count: 64)
        t.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: px, bytesPerRow: 16)
        return t
    }

    static func makeTestPattern(device: MTLDevice, width: Int = 1920, height: Int = 1080) -> MTLTexture? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(width), H = CGFloat(height)
        ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)   // y down like the rest of the app
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        let step = H / 9
        ctx.setStrokeColor(CGColor(gray: 0.55, alpha: 1)); ctx.setLineWidth(2)
        var x = W / 2; while x > 0 { x -= step }
        while x <= W { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)); x += step }
        var y = H / 2; while y > 0 { y -= step }
        while y <= H { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)); y += step }
        ctx.strokePath()

        ctx.setStrokeColor(CGColor(gray: 0.35, alpha: 1)); ctx.setLineWidth(2)
        ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: W, y: H))
        ctx.move(to: CGPoint(x: W, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: H)); ctx.strokePath()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(x: W / 2 - H * 0.4, y: H * 0.1, width: H * 0.8, height: H * 0.8))
        ctx.strokeEllipse(in: CGRect(x: W / 2 - H * 0.15, y: H * 0.35, width: H * 0.3, height: H * 0.3))
        ctx.setLineWidth(8); ctx.stroke(CGRect(x: 4, y: 4, width: W - 8, height: H - 8))

        // Colour bars and the corner colours used by the handles.
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1)]
        let bw = H * 0.5 / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: W / 2 - H * 0.25 + CGFloat(i) * bw, y: H * 0.72, width: bw, height: H * 0.06))
        }
        let cc: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.25, 0.25), (0.25, 1, 0.35), (0.3, 0.55, 1), (1, 0.9, 0.2)]
        let r = H * 0.07
        let pos = [CGPoint(x: 0, y: 0), CGPoint(x: W - r, y: 0), CGPoint(x: W - r, y: H - r), CGPoint(x: 0, y: H - r)]
        for (i, p) in pos.enumerated() {
            ctx.setFillColor(CGColor(red: cc[i].0, green: cc[i].1, blue: cc[i].2, alpha: 1))
            ctx.fill(CGRect(origin: p, size: CGSize(width: r, height: r)))
        }
        // Arrow pointing up so flips are obvious.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.move(to: CGPoint(x: W / 2, y: H * 0.2)); ctx.addLine(to: CGPoint(x: W / 2 + H * 0.06, y: H * 0.3))
        ctx.addLine(to: CGPoint(x: W / 2 - H * 0.06, y: H * 0.3)); ctx.fillPath()

        guard let img = ctx.makeImage() else { return nil }
        // CG images are stored top row first once drawn through the flipped context.
        return makeTexture(device: device, image: img)
    }
}
