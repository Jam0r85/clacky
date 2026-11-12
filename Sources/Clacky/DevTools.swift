import AppKit
import ClackyCore
import Foundation
import SwiftUI

/// Offline helpers for tuning sounds without the menu bar UI or any permissions.
enum DevTools {
    /// Types a sentence through the real mixer for every switch and writes stereo WAVs.
    static func renderDemo(to directory: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ids = RecordedSwitch.all.map { "rec:\($0.id)" }
        let engine = ClackEngine()
        engine.volume = 1

        // Shift+T, then the sentence, a typo fixed with backspace, and Enter.
        let text = "he quick brown fox jumps over the lazy dogg"
        var events: [(time: Double, key: UInt16, down: Bool)] = []
        var t = 0.1
        func press(_ key: UInt16, hold: Double = 0.08) {
            events.append((t, key, true))
            events.append((t + hold, key, false))
            t += 0.105 + Double((KeyLayout.hash(key) % 40)) / 1000
        }
        events.append((t, 56, true)); t += 0.06
        press(17) // T
        events.append((t - 0.05, 56, false))
        for ch in text {
            if let key = keyCodes[ch] { press(key, hold: ch == " " ? 0.1 : 0.08) }
        }
        t += 0.15
        press(51); t += 0.1
        press(36, hold: 0.11)
        let duration = t + 0.6

        print(String(format: "%-24@ %6@ %8@ %8@ %8@ %8@ %9@", "source", "peak", "letter", "space", "release",
                     "load ms", "spread dB"))
        for id in ids {
            let started = CFAbsoluteTimeGetCurrent()
            guard (try? engine.select(sourceID: id)) != nil else {
                print("\(id): failed to load")
                continue
            }
            let loadMs = (CFAbsoluteTimeGetCurrent() - started) * 1000

            let (left, right) = render(engine: engine, events: events, duration: duration)
            let peak = max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
            func level(_ key: UInt16, _ down: Bool) -> Float {
                let (l, r) = render(engine: engine, events: [(0, key, down)], duration: 0.3)
                return sqrtf(powf(Levels.loudness(l), 2) + powf(Levels.loudness(r), 2))
            }
            let letter = level(3, true), space = level(49, true), release = level(3, false)

            // Spatial check: a far-left key should be louder in the left ear and vice versa.
            let (ql, qr) = render(engine: engine, events: [(0, 12, true)], duration: 0.3)
            let (pl, pr) = render(engine: engine, events: [(0, 35, true)], duration: 0.3)
            let spread = db(energy(ql) / energy(qr)) - db(energy(pl) / energy(pr))

            let name = id.replacingOccurrences(of: ":", with: "-")
            writeWAV(left: left, right: right, to: directory.appendingPathComponent("\(name).wav"))
            print(String(format: "%-24@ %6.2f %8.3f %8.3f %8.3f %8.1f %9.1f", id, peak, letter, space, release,
                         loadMs, spread))
        }
        return 0
    }

    private static func render(engine: ClackEngine, events: [(time: Double, key: UInt16, down: Bool)],
                               duration: Double) -> ([Float], [Float]) {
        let mixer = kc_mixer_create()!
        defer { kc_mixer_destroy(mixer) }
        kc_mixer_set_volume(mixer, 1)
        let sr = Double(ClackEngine.sampleRate), block = 256
        let total = Int(duration * sr)
        var left = [Float](repeating: 0, count: total), right = left
        var queue = events.sorted { $0.time < $1.time }[...]
        var pos = 0
        while pos < total {
            while let e = queue.first, Int(e.time * sr) < pos + block {
                if var p = engine.voice(for: e.key, down: e.down) { kc_mixer_trigger(mixer, &p) }
                queue = queue.dropFirst()
            }
            let n = min(block, total - pos)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    _ = kc_mixer_render(mixer, UInt32(n), l.baseAddress! + pos, r.baseAddress! + pos)
                }
            }
            pos += n
        }
        return (left, right)
    }

    private static func energy(_ x: [Float]) -> Float { x.reduce(0) { $0 + $1 * $1 } + 1e-12 }
    private static func db(_ ratio: Float) -> Float { 10 * log10f(ratio) }

    private static func writeWAV(left: [Float], right: [Float], to url: URL) {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let frames = UInt32(left.count), sr = UInt32(ClackEngine.sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * 4)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2)
        u32(sr); u32(sr * 4); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(frames * 4)
        for i in 0..<left.count {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, left[i])) * 32767)))
            u16(UInt16(bitPattern: Int16(max(-1, min(1, right[i])) * 32767)))
        }
        try? data.write(to: url)
    }

    /// Loads a Mechvibes pack folder and reports what it found.
    static func checkPack(at folder: URL) -> Int32 {
        do {
            let pack = try PackSource(folder: folder)
            var found = 0, releases = 0
            for code in UInt16(0)..<128 {
                if pack.sound(for: code, down: true) != nil { found += 1 }
                if pack.sound(for: code, down: false) != nil { releases += 1 }
            }
            print("\(pack.displayName): \(found) keys with press sounds, \(releases) with release sounds, " +
                  "\(pack.byteCount / 1024) KB")
            return 0
        } catch {
            print("Failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Renders the panel in light and dark mode side by side (as if listening), for docs and review.
    static func exportPanel(to url: URL) -> Int32 {
        _ = NSApplication.shared
        let model = AppModel(checksForUpdates: false)
        model.refresh()
        model.markListeningForPreview()
        switch ProcessInfo.processInfo.environment["CLACKY_PREVIEW_UPDATE"] {
        case "ready": model.updater.previewStatus(.waitingToRestart(version: "1.1.0"), userInitiated: false)
        case "manual": model.updater.previewStatus(.manualUpdateNeeded(version: "1.1.0", page: Updater.releasesAPI),
                                                   userInitiated: false)
        case "failed": model.updater.previewStatus(.failed("Update failed: The Internet connection appears to be offline."),
                                                   userInitiated: true)
        case "current": model.updater.previewStatus(.upToDate, userInitiated: true)
        default: break
        }

        var shots: [NSBitmapImageRep] = []
        for (name, fill) in [(NSAppearance.Name.aqua, NSColor(white: 0.95, alpha: 1)),
                             (NSAppearance.Name.darkAqua, NSColor(white: 0.16, alpha: 1))] {
            let host = NSHostingView(rootView: PanelView(model: model))
            let size = host.fittingSize
            let window = SnapshotPanel(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.alphaValue = 0.01
            window.appearance = NSAppearance(named: name)
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            container.wantsLayer = true
            container.layer?.backgroundColor = fill.cgColor
            container.layer?.cornerRadius = 14
            host.frame = container.bounds
            container.addSubview(host)
            window.contentView = container
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
            container.cacheDisplay(in: container.bounds, to: rep)
            shots.append(rep)
            window.orderOut(nil)
        }

        let gap = 24, scale = shots[0].pixelsWide / Int(shots[0].size.width)
        let width = shots.reduce(0) { $0 + $1.pixelsWide } + gap * scale
        let height = shots.map(\.pixelsHigh).max() ?? 0
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        var x = 0
        for shot in shots {
            shot.draw(in: NSRect(x: x, y: height - shot.pixelsHigh, width: shot.pixelsWide, height: shot.pixelsHigh))
            x += shot.pixelsWide + gap * scale
        }
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
        return 0
    }

    /// Checks the real release feed and verifies the latest download, without installing anything.
    static func checkUpdate() -> Int32 {
        let done = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            let updater = Updater(startChecking: false)
            do {
                let release = try await updater.fetchLatestRelease()
                let newer = Updater.version(release.version, isNewerThan: updater.currentVersion)
                print("Running \(updater.currentVersion); latest release is \(release.version) (\(newer ? "newer" : "not newer"))")
                guard let zip = release.zip else { throw Updater.UpdateError("the release has no Clacky.zip") }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Clacky-check-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let app = try await Updater.download(zip, version: release.version, into: dir)
                print("Downloaded and verified \(app.lastPathComponent) \(release.version): signed by team \(Updater.teamID)")
            } catch {
                print("Update check failed: \(error.localizedDescription)")
                code = 1
            }
            done.signal()
        }
        done.wait()

        // A build that isn't Developer ID signed (like a local dev build) must be refused.
        let local = URL(fileURLWithPath: "build/Clacky.app")
        if FileManager.default.fileExists(atPath: local.path) {
            do {
                try Updater.verifySignature(of: local, identifier: Bundle.main.bundleIdentifier ?? "io.github.jam0r85.clacky")
                print("Local build/Clacky.app passes the signature check (it's Developer ID signed)")
            } catch {
                print("Local build/Clacky.app is refused, as it should be: \(error.localizedDescription)")
            }
        }
        return code
    }

    static func exportMenuBarIcon(to url: URL) -> Int32 {
        let scale: CGFloat = 8
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(18 * scale * 2 + 24), pixelsHigh: Int(18 * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
        Icons.keycap(active: true).draw(in: NSRect(x: 0, y: 0, width: 18 * scale, height: 18 * scale))
        Icons.keycap(active: false).draw(in: NSRect(x: 18 * scale + 24, y: 0, width: 18 * scale, height: 18 * scale))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return 0
    }

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
    ]
}

/// Key-capable panel so controls render in their active (tinted) state for screenshots.
private final class SnapshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
