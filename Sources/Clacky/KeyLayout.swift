import Foundation

/// Physical size class of a key: bigger keys have stabilisers and a deeper sound.
enum KeySize: Int, CaseIterable {
    case standard, wide, space

    var variantCount: Int {
        switch self {
        case .standard: return 6
        case .wide: return 3
        case .space: return 2
        }
    }
}

struct KeyInfo {
    /// Horizontal position on the keyboard, 0 = far left, 1 = far right.
    let x: Float
    let size: KeySize
    /// W3C `KeyboardEvent.code` name, used to look keys up in sound packs.
    let code: String?
}

/// Maps macOS virtual key codes (kVK_*) to where the key sits on an ANSI Mac keyboard.
enum KeyLayout {
    static func info(for keyCode: UInt16) -> KeyInfo {
        table[keyCode] ?? KeyInfo(x: 0.5, size: .standard, code: nil)
    }

    /// Stable per-key hash, so each key keeps its own slightly different voice.
    static func hash(_ keyCode: UInt16) -> UInt32 {
        var x = UInt32(keyCode) &+ 0x9E37_79B9
        x = (x ^ (x >> 16)) &* 0x85EB_CA6B
        x = (x ^ (x >> 13)) &* 0xC2B2_AE35
        return x ^ (x >> 16)
    }

    /// Width of the main block in key units (number row: 13 keys + 1.5u delete).
    private static let width: Float = 14.5

    private static let table: [UInt16: KeyInfo] = {
        var t = [UInt16: KeyInfo]()
        func put(_ keyCode: UInt16, _ units: Float, _ code: String, _ size: KeySize = .standard) {
            t[keyCode] = KeyInfo(x: min(max(units / width, 0), 1), size: size, code: code)
        }
        func row(_ keys: [(UInt16, String)], from start: Float) {
            for (i, key) in keys.enumerated() { put(key.0, start + Float(i), key.1) }
        }

        // Function row
        put(53, 0.5, "Escape")
        row([(122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
             (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12")], from: 1.75)

        // Number row
        row([(50, "Backquote"), (18, "Digit1"), (19, "Digit2"), (20, "Digit3"), (21, "Digit4"),
             (23, "Digit5"), (22, "Digit6"), (26, "Digit7"), (28, "Digit8"), (25, "Digit9"),
             (29, "Digit0"), (27, "Minus"), (24, "Equal")], from: 0.5)
        put(51, 13.75, "Backspace", .wide)

        // Top letter row
        put(48, 0.75, "Tab", .wide)
        row([(12, "KeyQ"), (13, "KeyW"), (14, "KeyE"), (15, "KeyR"), (17, "KeyT"), (16, "KeyY"),
             (32, "KeyU"), (34, "KeyI"), (31, "KeyO"), (35, "KeyP"), (33, "BracketLeft"),
             (30, "BracketRight")], from: 2.0)
        put(42, 14.0, "Backslash")

        // Home row
        put(57, 0.875, "CapsLock", .wide)
        row([(0, "KeyA"), (1, "KeyS"), (2, "KeyD"), (3, "KeyF"), (5, "KeyG"), (4, "KeyH"),
             (38, "KeyJ"), (40, "KeyK"), (37, "KeyL"), (41, "Semicolon"), (39, "Quote")], from: 2.25)
        put(36, 13.6, "Enter", .wide)

        // Bottom letter row
        put(56, 1.125, "ShiftLeft", .wide)
        put(10, 0.9, "IntlBackslash")
        row([(6, "KeyZ"), (7, "KeyX"), (8, "KeyC"), (9, "KeyV"), (11, "KeyB"), (45, "KeyN"),
             (46, "KeyM"), (43, "Comma"), (47, "Period"), (44, "Slash")], from: 2.75)
        put(60, 13.4, "ShiftRight", .wide)

        // Space row
        put(63, 0.5, "Fn")
        put(59, 1.5, "ControlLeft")
        put(58, 2.5, "AltLeft")
        put(55, 3.6, "MetaLeft")
        put(49, 7.0, "Space", .space)
        put(54, 10.4, "MetaRight")
        put(61, 11.5, "AltRight")
        put(62, 11.5, "ControlRight")
        put(123, 12.5, "ArrowLeft")
        put(125, 13.5, "ArrowDown")
        put(126, 13.5, "ArrowUp")
        put(124, 14.5, "ArrowRight")

        // Navigation cluster and extra function keys (right of the main block)
        for (code, name) in [(114, "Insert"), (115, "Home"), (116, "PageUp"), (117, "Delete"),
                             (119, "End"), (121, "PageDown"), (105, "F13"), (107, "F14"),
                             (113, "F15"), (106, "F16"), (64, "F17"), (79, "F18"), (80, "F19"),
                             (90, "F20")] as [(UInt16, String)] {
            put(code, 15.5, name)
        }

        // Keypad (far right)
        for (code, name) in [(65, "NumpadDecimal"), (67, "NumpadMultiply"), (69, "NumpadAdd"),
                             (71, "NumLock"), (75, "NumpadDivide"), (78, "NumpadSubtract"),
                             (81, "NumpadEqual"), (83, "Numpad1"), (84, "Numpad2"), (85, "Numpad3"),
                             (86, "Numpad4"), (87, "Numpad5"), (88, "Numpad6"), (89, "Numpad7"),
                             (91, "Numpad8"), (92, "Numpad9")] as [(UInt16, String)] {
            put(code, 17.0, name)
        }
        put(76, 17.0, "NumpadEnter", .wide)
        put(82, 17.0, "Numpad0", .wide)
        return t
    }()
}

/// Legacy Mechvibes (V1) packs key their sounds by iohook scan codes.
enum IOHookCodes {
    static func codeName(_ code: Int) -> String? { table[code] }

    private static let table: [Int: String] = {
        var t: [Int: String] = [
            1: "Escape", 14: "Backspace", 15: "Tab", 28: "Enter", 29: "ControlLeft",
            42: "ShiftLeft", 54: "ShiftRight", 56: "AltLeft", 57: "Space", 58: "CapsLock",
            12: "Minus", 13: "Equal", 26: "BracketLeft", 27: "BracketRight", 39: "Semicolon",
            40: "Quote", 41: "Backquote", 43: "Backslash", 51: "Comma", 52: "Period", 53: "Slash",
            55: "NumpadMultiply", 69: "NumLock", 74: "NumpadSubtract", 78: "NumpadAdd",
            83: "NumpadDecimal", 87: "F11", 88: "F12", 91: "F13", 92: "F14", 93: "F15",
            99: "F16", 100: "F17", 101: "F18", 102: "F19", 103: "F20",
            3597: "NumpadEqual", 3612: "NumpadEnter", 3613: "ControlRight", 3637: "NumpadDivide",
            3640: "AltRight", 3655: "Home", 3657: "PageUp", 3663: "End", 3665: "PageDown",
            3666: "Insert", 3667: "Delete", 3675: "MetaLeft", 3676: "MetaRight",
            57400: "AltRight", 57415: "Home", 57416: "ArrowUp", 57417: "PageUp", 57419: "ArrowLeft",
            57421: "ArrowRight", 57423: "End", 57424: "ArrowDown", 57425: "PageDown",
            57426: "Insert", 57427: "Delete", 57435: "MetaLeft", 57436: "MetaRight",
            61000: "ArrowUp", 61003: "ArrowLeft", 61005: "ArrowRight", 61008: "ArrowDown",
        ]
        for (i, n) in (1...9).enumerated() { t[2 + i] = "Digit\(n)" }
        t[11] = "Digit0"
        for (i, c) in "QWERTYUIOP".enumerated() { t[16 + i] = "Key\(c)" }
        for (i, c) in "ASDFGHJKL".enumerated() { t[30 + i] = "Key\(c)" }
        for (i, c) in "ZXCVBNM".enumerated() { t[44 + i] = "Key\(c)" }
        for i in 0..<10 { t[59 + i] = "F\(i + 1)" }
        for (code, n) in [(71, 7), (72, 8), (73, 9), (75, 4), (76, 5), (77, 6), (79, 1), (80, 2), (81, 3), (82, 0)] {
            t[code] = "Numpad\(n)"
        }
        return t
    }()
}
