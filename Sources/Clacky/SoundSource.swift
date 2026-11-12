import AVFoundation
import Foundation

/// A mono 48 kHz sample buffer. The memory is owned by the `SoundSource` that vended it.
struct Sound {
    let samples: UnsafePointer<Float>
    let length: UInt32
}

/// Something that can say which sound a key makes.
protocol SoundSource: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// Whether each press should get a small random pitch change.
    var randomPitch: Bool { get }
    func sound(for keyCode: UInt16, down: Bool) -> Sound?
}

/// Owns immutable sample memory for the lifetime of a source.
final class SampleStore {
    private var buffers: [UnsafeMutableBufferPointer<Float>] = []

    func store(_ samples: [Float]) -> Sound {
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(samples.count, 1))
        _ = buf.initialize(from: samples)
        if samples.isEmpty { buf[0] = 0 }
        buffers.append(buf)
        return Sound(samples: UnsafePointer(buf.baseAddress!), length: UInt32(max(samples.count, 1)))
    }

    var byteCount: Int { buffers.reduce(0) { $0 + $1.count * MemoryLayout<Float>.size } }

    deinit { buffers.forEach { $0.deallocate() } }
}

// MARK: - Mechvibes-format sound packs

enum SoundPackError: LocalizedError {
    case noConfig
    case badConfig(String)
    case noSounds

    var errorDescription: String? {
        switch self {
        case .noConfig: return "No config.json was found in that folder or zip."
        case .badConfig(let why): return "The pack's config.json couldn't be read: \(why)"
        case .noSounds: return "The pack didn't define any sounds this Mac could play."
        }
    }
}

/// Plays a Mechvibes sound pack (V1 or V2 config). See README for the format.
final class PackSource: SoundSource {
    let id: String
    let displayName: String
    let randomPitch: Bool
    private let store = SampleStore()
    private var downSounds: [String: Sound] = [:]
    private var upSounds: [String: Sound] = [:]
    private var fallback: [Sound] = []

    /// Longest slice we keep per key, so a bad timing can't pin a minute of audio.
    private static let maxSliceSeconds: Double = 1.0

    init(folder: URL) throws {
        guard let configURL = PackSource.findConfig(in: folder) else { throw SoundPackError.noConfig }
        let root = configURL.deletingLastPathComponent()
        let data = try Data(contentsOf: configURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SoundPackError.badConfig("not a JSON object")
        }

        id = "pack:\(folder.lastPathComponent)"
        displayName = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        let options = json["options"] as? [String: Any]
        randomPitch = options?["random_pitch"] as? Bool ?? false
        let gain = Float((options?["recommended_volume"] as? NSNumber)?.doubleValue ?? 1.0)

        // Collect (code, segments, file) for every key, from either format.
        var entries: [(code: String, down: Bool, file: String?, segment: (Double, Double)?)] = []

        if let defs = (json["definitions"] ?? json["defs"]) as? [String: Any] {
            let mainFile = json["audio_file"] as? String
            for (code, value) in defs {
                guard let def = value as? [String: Any] else { continue }
                let file = (def["audio_file"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? mainFile
                let timing = (def["timing"] as? [[NSNumber]]) ?? []
                if timing.isEmpty {
                    entries.append((code, true, file, nil))
                } else if timing.count <= 2 {
                    for (i, seg) in timing.enumerated() where seg.count >= 2 {
                        entries.append((code, i == 0, file, (seg[0].doubleValue, seg[1].doubleValue)))
                    }
                }
            }
        } else if let defines = json["defines"] as? [String: Any] {
            // V1: keys are iohook codes; a leading zero ("030") marks the release sound.
            let multi = (json["key_define_type"] as? String) == "multi"
            let mainFile = json["sound"] as? String
            for (key, value) in defines {
                let isRelease = key.count > 1 && key.hasPrefix("0")
                guard let n = Int(key), let code = IOHookCodes.codeName(n) else { continue }
                if multi {
                    guard let file = value as? String, !file.isEmpty else { continue }
                    entries.append((code, !isRelease, file, nil))
                } else if let seg = value as? [NSNumber], seg.count >= 2 {
                    let start = seg[0].doubleValue
                    entries.append((code, !isRelease, mainFile, (start, start + seg[1].doubleValue)))
                }
            }
        } else {
            throw SoundPackError.badConfig("it has no definitions")
        }

        // Decode each referenced file once, then cut out each key's slice.
        var decoded: [String: [Float]] = [:]
        var slices: [(code: String, down: Bool, samples: [Float])] = []
        for entry in entries {
            guard let file = entry.file else { continue }
            if decoded[file] == nil {
                let url = root.appendingPathComponent(file)
                decoded[file] = (try? AudioDecoder.decodeMono(url: url, sampleRate: Double(ClackEngine.sampleRate))) ?? []
            }
            guard let audio = decoded[file], !audio.isEmpty else { continue }
            let sr = Double(ClackEngine.sampleRate)
            var lo = 0, hi = audio.count
            if let (startMs, endMs) = entry.segment {
                lo = max(0, min(audio.count, Int(startMs / 1000 * sr)))
                hi = max(lo, min(audio.count, Int(endMs / 1000 * sr)))
            }
            hi = min(hi, lo + Int(Self.maxSliceSeconds * sr))
            guard hi - lo > 16 else { continue }
            slices.append((entry.code, entry.down, Self.faded(Array(audio[lo..<hi]))))
        }
        guard !slices.isEmpty else { throw SoundPackError.noSounds }

        let downLevels = slices.filter(\.down).map { Levels.loudness($0.samples) }.filter { $0 > 0 }.sorted()
        let reference = downLevels.isEmpty ? 0 : downLevels[downLevels.count / 2]
        let packGain = reference > 0 ? Levels.target * min(max(gain, 0.1), 2) / reference : 1
        for slice in slices {
            let sound = store.store(Levels.scaled(slice.samples, by: packGain))
            if slice.down {
                downSounds[slice.code] = sound
                fallback.append(sound)
            } else {
                upSounds[slice.code] = sound
            }
        }
        if fallback.isEmpty { fallback = Array(upSounds.values) }
    }

    func sound(for keyCode: UInt16, down: Bool) -> Sound? {
        let code = KeyLayout.info(for: keyCode).code
        if down {
            if let code, let s = downSounds[code] { return s }
            // Keys the pack doesn't define borrow a consistent sound from one that it does.
            guard !fallback.isEmpty else { return nil }
            return fallback[Int(KeyLayout.hash(keyCode) % UInt32(fallback.count))]
        }
        guard let code else { return nil }
        return upSounds[code]
    }

    var byteCount: Int { store.byteCount }

    private static func faded(_ x: [Float]) -> [Float] {
        var x = x
        let fadeIn = min(x.count / 4, 24), fadeOut = min(x.count / 4, 240)
        for i in 0..<fadeIn { x[i] *= Float(i) / Float(fadeIn) }
        for i in 0..<fadeOut { x[x.count - 1 - i] *= Float(i) / Float(fadeOut) }
        return x
    }

    static func findConfig(in folder: URL) -> URL? {
        let fm = FileManager.default
        let direct = folder.appendingPathComponent("config.json")
        if fm.fileExists(atPath: direct.path) { return direct }
        // Zips often wrap the pack in one folder; look one or two levels down.
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            if url.lastPathComponent == "config.json", !url.path.contains("__MACOSX") { return url }
        }
        return nil
    }
}

enum AudioDecoder {
    /// Decodes any Core Audio readable file (WAV, MP3, OGG, FLAC, AIFF, M4A) to mono float.
    static func decodeMono(url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return [] }
        try file.read(into: inBuf)

        let n = Int(inBuf.frameLength), channels = Int(inFormat.channelCount)
        guard n > 0, channels > 0, let data = inBuf.floatChannelData else { return [] }

        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate,
                                       channels: 1, interleaved: false)!
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(n)) else { return [] }
        mono.frameLength = AVAudioFrameCount(n)
        let m = mono.floatChannelData![0]
        for i in 0..<n {
            var sum: Float = 0
            for c in 0..<channels { sum += data[c][i] }
            m[i] = sum / Float(channels)
        }
        if inFormat.sampleRate == sampleRate { return Array(UnsafeBufferPointer(start: m, count: n)) }

        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: monoFormat, to: outFormat) else { return [] }
        let capacity = AVAudioFrameCount(Double(n) * sampleRate / inFormat.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return mono
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

// MARK: - Bundled real recordings (from kbsim, MIT)

struct RecordedSwitch: Identifiable {
    let id: String
    let folder: String
    let name: String
    /// Fits a tile in the panel.
    let shortName: String
    let kind: String
    /// Stem colour, used for the little switch glyph in the panel.
    let color: UInt32

    /// Grouped clicky → tactile → linear → other.
    static let all: [RecordedSwitch] = [
        .init(id: "mx-blue", folder: "mxblue", name: "Cherry MX Blue", shortName: "MX Blue",
              kind: "Clicky", color: 0x3B7BF2),
        .init(id: "box-navy", folder: "boxnavy", name: "Kailh Box Navy", shortName: "Box Navy",
              kind: "Clicky · heavy", color: 0x24366E),
        .init(id: "alps-blue", folder: "bluealps", name: "Alps Blue", shortName: "Alps Blue",
              kind: "Clicky · vintage", color: 0x7DB9F0),
        .init(id: "mx-brown", folder: "mxbrown", name: "Cherry MX Brown", shortName: "MX Brown",
              kind: "Tactile", color: 0x8B5A33),
        .init(id: "holy-panda", folder: "holypanda", name: "Holy Panda", shortName: "Holy Panda",
              kind: "Tactile · thocky", color: 0xC98FD0),
        .init(id: "mx-black", folder: "mxblack", name: "Cherry MX Black", shortName: "MX Black",
              kind: "Linear · heavy", color: 0x2A2A2E),
        .init(id: "red-ink", folder: "redink", name: "Gateron Red Ink", shortName: "Red Ink",
              kind: "Linear · light", color: 0xE0393E),
        .init(id: "black-ink", folder: "blackink", name: "Gateron Black Ink", shortName: "Black Ink",
              kind: "Linear · deep", color: 0x4A4A55),
        .init(id: "nk-cream", folder: "cream", name: "NovelKeys Cream", shortName: "NK Cream",
              kind: "Linear · POM", color: 0xF1E3BE),
        .init(id: "alpaca", folder: "alpaca", name: "Alpaca", shortName: "Alpaca",
              kind: "Linear · smooth", color: 0xF29BB8),
        .init(id: "tealios", folder: "turquoise", name: "Turquoise Tealios", shortName: "Tealios",
              kind: "Linear · premium", color: 0x2FBFBF),
        .init(id: "topre", folder: "topre", name: "Topre", shortName: "Topre",
              kind: "Electro-capacitive", color: 0x9A96A8),
        .init(id: "buckling-spring", folder: "buckling", name: "Buckling Spring", shortName: "Buckling Spring",
              kind: "IBM Model M", color: 0xC9BFA8),
    ]

    static let `default` = all.first { $0.id == "holy-panda" }!

    static func named(_ id: String) -> RecordedSwitch? { all.first { $0.id == id } }

    /// Where the recordings live: inside the app bundle, or the repo when run from `swift run`.
    static var directory: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Switches"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Switches"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

final class RecordedSource: SoundSource {
    let recording: RecordedSwitch
    private let store = SampleStore()
    private var press: [String: Sound] = [:]
    private var release: [String: Sound] = [:]
    private var generic: [Sound] = []

    var id: String { "rec:\(recording.id)" }
    var displayName: String { recording.name }
    var randomPitch: Bool { true }

    init(recording: RecordedSwitch, directory: URL) throws {
        self.recording = recording
        let base = directory.appendingPathComponent(recording.folder)
        let sr = Double(ClackEngine.sampleRate)

        func load(_ path: String) -> [Float]? {
            let url = base.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let audio = try? AudioDecoder.decodeMono(url: url, sampleRate: sr), audio.count > 64 else { return nil }
            return RecordedSource.tidy(audio)
        }

        var raw: [(kind: String, down: Bool, samples: [Float])] = []
        for i in 0..<5 { if let s = load("press/GENERIC_R\(i).mp3") { raw.append(("GENERIC", true, s)) } }
        for name in ["SPACE", "ENTER", "BACKSPACE"] {
            if let s = load("press/\(name).mp3") { raw.append((name, true, s)) }
        }
        for name in ["GENERIC", "SPACE", "ENTER", "BACKSPACE"] {
            if let s = load("release/\(name).mp3") { raw.append((name, false, s)) }
        }
        let generics = raw.filter { $0.kind == "GENERIC" && $0.down }
        guard !generics.isEmpty else { throw SoundPackError.noSounds }

        // The source recordings vary wildly in level between key types, so each one is
        // matched to the letter keys: big keys a touch louder, releases always quieter.
        let reference = generics.map { Levels.loudness($0.samples) }.reduce(0, +) / Float(generics.count)
        let baseGain = reference > 0 ? Levels.target / reference : 1
        for item in raw {
            let own = Levels.loudness(item.samples)
            var gain = baseGain
            if own > 0 && reference > 0 && !(item.kind == "GENERIC" && item.down) {
                let ratio = own / reference
                let allowed = item.down ? min(max(ratio, 0.9), 1.3) : min(max(ratio, 0.25), 0.6)
                gain = baseGain * allowed / ratio
            }
            let sound = store.store(Levels.scaled(item.samples, by: gain))
            if item.kind == "GENERIC" && item.down {
                generic.append(sound)
            } else if item.down {
                press[item.kind] = sound
            } else {
                release[item.kind] = sound
            }
        }
    }

    func sound(for keyCode: UInt16, down: Bool) -> Sound? {
        let kind: String
        switch KeyLayout.info(for: keyCode).code {
        case "Space": kind = "SPACE"
        case "Enter", "NumpadEnter": kind = "ENTER"
        case "Backspace", "Delete", "ShiftLeft", "ShiftRight": kind = "BACKSPACE"
        default: kind = "GENERIC"
        }
        if down {
            if let s = press[kind] { return s }
            return generic[Int(KeyLayout.hash(keyCode) % UInt32(generic.count))]
        }
        return release[kind] ?? release["GENERIC"]
    }

    /// Drops MP3 encoder padding / leading silence (lower latency) and fades the tail.
    private static func tidy(_ x: [Float]) -> [Float] {
        let peak = x.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return x }
        let onset = x.firstIndex { abs($0) > peak * 0.02 } ?? 0
        let start = max(0, onset - 48)
        var out = Array(x[start...])
        let fadeIn = min(onset - start, out.count)
        for i in 0..<fadeIn { out[i] *= Float(i) / Float(max(fadeIn, 1)) }
        let fadeOut = min(out.count / 4, 240)
        for i in 0..<fadeOut { out[out.count - 1 - i] *= Float(i) / Float(fadeOut) }
        return out
    }
}

/// Loudness matching, so every switch, pack and key type sits at a similar level.
enum Levels {
    /// Target RMS over the first 50 ms of a key press (peaks land around 0.4-0.6).
    static let target: Float = 0.05
    static let ceiling: Float = 0.95

    /// RMS of the 50 ms after the attack: what you hear as "how loud is this click".
    static func loudness(_ x: [Float]) -> Float {
        let peak = x.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return 0 }
        let onset = x.firstIndex { abs($0) > peak * 0.02 } ?? 0
        let end = min(x.count, onset + Int(0.05 * ClackEngine.sampleRate))
        guard end > onset else { return 0 }
        var sum: Float = 0
        for i in onset..<end { sum += x[i] * x[i] }
        return sqrtf(sum / Float(end - onset))
    }

    /// Applies a gain, backing it off if the result would clip.
    static func scaled(_ x: [Float], by gain: Float) -> [Float] {
        let peak = x.reduce(0) { max($0, abs($1)) }
        let g = peak * gain > ceiling ? ceiling / peak : gain
        return x.map { $0 * g }
    }
}
