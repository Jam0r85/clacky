import Foundation

// A keystroke is modelled as a few impacts (click jacket snap, bottom-out, top-out...).
// Each impact excites filtered noise (the transient) and damped resonances (keycap,
// plate, case, spring). All times are in milliseconds.

/// Band-passed noise transient. `amp` is its peak contribution.
struct Burst {
    var freq: Float
    var q: Float
    var decay: Float
    var amp: Float
}

/// Exponentially decaying sine (a resonant mode). `decay` is the time constant.
struct Mode {
    var freq: Float
    var decay: Float
    var amp: Float
}

struct Impact {
    var at: Float
    var bursts: [Burst] = []
    var modes: [Mode] = []
}

struct SwitchProfile: Identifiable {
    let id: String
    let name: String
    let kind: String
    let down: [Impact]
    let up: [Impact]
    /// Output low-pass cutoff in Hz: lower = darker, more muted.
    let brightness: Float
    /// Loudness trim relative to the other profiles.
    let loudness: Float

    static let all: [SwitchProfile] = [mxBlue, mxBrown, mxRed, holyPanda, topre, bucklingSpring]
    static let `default` = mxBlue

    static func named(_ id: String) -> SwitchProfile? { all.first { $0.id == id } }
}

extension SwitchProfile {
    /// Clicky: the click jacket snaps on the way down *and* up, then a bright bottom-out.
    static let mxBlue = SwitchProfile(
        id: "mx-blue", name: "MX Blue", kind: "Clicky",
        down: [
            Impact(at: 0, bursts: [Burst(freq: 4800, q: 2.5, decay: 0.35, amp: 1.0),
                                   Burst(freq: 2600, q: 4, decay: 0.5, amp: 0.35)],
                   modes: [Mode(freq: 3400, decay: 2.5, amp: 0.45), Mode(freq: 5900, decay: 1.6, amp: 0.3),
                           Mode(freq: 7600, decay: 1.0, amp: 0.15)]),
            Impact(at: 1.1, bursts: [Burst(freq: 4200, q: 3, decay: 0.25, amp: 0.35)]),
            Impact(at: 9, bursts: [Burst(freq: 2300, q: 1.2, decay: 1.4, amp: 0.55),
                                   Burst(freq: 900, q: 1.0, decay: 2.5, amp: 0.25)],
                   modes: [Mode(freq: 1850, decay: 6, amp: 0.28), Mode(freq: 2950, decay: 4, amp: 0.18),
                           Mode(freq: 640, decay: 11, amp: 0.22), Mode(freq: 160, decay: 22, amp: 0.08),
                           Mode(freq: 6800, decay: 45, amp: 0.025)]),
        ],
        up: [
            Impact(at: 0, bursts: [Burst(freq: 4400, q: 2.5, decay: 0.3, amp: 0.7)],
                   modes: [Mode(freq: 3200, decay: 2, amp: 0.3), Mode(freq: 5600, decay: 1.4, amp: 0.2)]),
            Impact(at: 7, bursts: [Burst(freq: 2700, q: 1.4, decay: 1.0, amp: 0.35)],
                   modes: [Mode(freq: 2300, decay: 4, amp: 0.16), Mode(freq: 780, decay: 8, amp: 0.1)]),
        ],
        brightness: 13000, loudness: 1.0)

    /// Tactile: a soft scratchy bump, then a moderate, slightly muted bottom-out.
    static let mxBrown = SwitchProfile(
        id: "mx-brown", name: "MX Brown", kind: "Tactile",
        down: [
            Impact(at: 0, bursts: [Burst(freq: 1700, q: 0.9, decay: 2.5, amp: 0.12)]),
            Impact(at: 11, bursts: [Burst(freq: 1900, q: 1.1, decay: 1.6, amp: 0.6),
                                    Burst(freq: 800, q: 0.9, decay: 2.5, amp: 0.3)],
                   modes: [Mode(freq: 1600, decay: 6.5, amp: 0.26), Mode(freq: 2500, decay: 4, amp: 0.15),
                           Mode(freq: 560, decay: 12, amp: 0.26), Mode(freq: 170, decay: 22, amp: 0.08),
                           Mode(freq: 5600, decay: 30, amp: 0.012)]),
        ],
        up: [
            Impact(at: 0, bursts: [Burst(freq: 2400, q: 1.4, decay: 1.1, amp: 0.32)],
                   modes: [Mode(freq: 2100, decay: 4.5, amp: 0.13), Mode(freq: 700, decay: 8, amp: 0.08)]),
        ],
        brightness: 9500, loudness: 0.95)

    /// Linear: smooth travel, a crisp clack at the bottom with a tiny stem bounce.
    static let mxRed = SwitchProfile(
        id: "mx-red", name: "MX Red", kind: "Linear",
        down: [
            Impact(at: 0, bursts: [Burst(freq: 2600, q: 1.1, decay: 1.3, amp: 0.65),
                                   Burst(freq: 1000, q: 0.9, decay: 2, amp: 0.25)],
                   modes: [Mode(freq: 2100, decay: 6, amp: 0.3), Mode(freq: 3300, decay: 3.5, amp: 0.2),
                           Mode(freq: 720, decay: 10, amp: 0.24), Mode(freq: 170, decay: 20, amp: 0.08),
                           Mode(freq: 6200, decay: 32, amp: 0.018)]),
            Impact(at: 1.5, bursts: [Burst(freq: 2900, q: 1.5, decay: 0.7, amp: 0.18)]),
        ],
        up: [
            Impact(at: 0, bursts: [Burst(freq: 3000, q: 1.5, decay: 0.9, amp: 0.36)],
                   modes: [Mode(freq: 2600, decay: 4, amp: 0.15), Mode(freq: 820, decay: 7, amp: 0.08)]),
        ],
        brightness: 12000, loudness: 1.0)

    /// Enthusiast tactile: heavy rounded bump, deep "thock" bottom-out, strong upstroke.
    static let holyPanda = SwitchProfile(
        id: "holy-panda", name: "Holy Panda", kind: "Tactile · Thocky",
        down: [
            Impact(at: 0, bursts: [Burst(freq: 1100, q: 1.0, decay: 2.2, amp: 0.22)],
                   modes: [Mode(freq: 900, decay: 5, amp: 0.08)]),
            Impact(at: 8, bursts: [Burst(freq: 950, q: 0.9, decay: 2.6, amp: 0.6),
                                   Burst(freq: 2000, q: 1.2, decay: 1.0, amp: 0.2)],
                   modes: [Mode(freq: 430, decay: 20, amp: 0.5), Mode(freq: 800, decay: 13, amp: 0.3),
                           Mode(freq: 1350, decay: 7, amp: 0.16), Mode(freq: 140, decay: 26, amp: 0.1)]),
        ],
        up: [
            Impact(at: 0, bursts: [Burst(freq: 1500, q: 1.1, decay: 1.6, amp: 0.4)],
                   modes: [Mode(freq: 950, decay: 9, amp: 0.2), Mode(freq: 520, decay: 14, amp: 0.14)]),
        ],
        brightness: 6500, loudness: 1.1)

    /// Electro-capacitive rubber dome: muted collapse, deep thock, signature upstroke.
    static let topre = SwitchProfile(
        id: "topre", name: "Topre", kind: "Electro-capacitive",
        down: [
            Impact(at: 0, bursts: [Burst(freq: 1300, q: 2.0, decay: 0.9, amp: 0.12)]),
            Impact(at: 6, bursts: [Burst(freq: 650, q: 0.8, decay: 3.5, amp: 0.55),
                                   Burst(freq: 1500, q: 1.0, decay: 1.2, amp: 0.12)],
                   modes: [Mode(freq: 310, decay: 26, amp: 0.5), Mode(freq: 580, decay: 16, amp: 0.3),
                           Mode(freq: 1050, decay: 8, amp: 0.12), Mode(freq: 120, decay: 30, amp: 0.1)]),
        ],
        up: [
            Impact(at: 0, bursts: [Burst(freq: 850, q: 0.9, decay: 3.0, amp: 0.5)],
                   modes: [Mode(freq: 390, decay: 20, amp: 0.36), Mode(freq: 720, decay: 12, amp: 0.2)]),
        ],
        brightness: 4800, loudness: 1.15)

    /// Classic buckling spring: loud buckle click, steel backplate and a ringing spring.
    static let bucklingSpring = SwitchProfile(
        id: "buckling-spring", name: "Buckling Spring", kind: "Model M style",
        down: [
            Impact(at: 0, bursts: [Burst(freq: 3300, q: 2.0, decay: 0.9, amp: 0.85),
                                   Burst(freq: 1800, q: 1.5, decay: 1.2, amp: 0.3)],
                   modes: [Mode(freq: 2700, decay: 7, amp: 0.3), Mode(freq: 4300, decay: 4, amp: 0.15)]),
            Impact(at: 4.5, bursts: [Burst(freq: 1700, q: 1.0, decay: 2.8, amp: 0.6)],
                   modes: [Mode(freq: 1150, decay: 14, amp: 0.3), Mode(freq: 360, decay: 24, amp: 0.3),
                           Mode(freq: 2150, decay: 90, amp: 0.07), Mode(freq: 2190, decay: 85, amp: 0.05),
                           Mode(freq: 3750, decay: 70, amp: 0.04)]),
        ],
        up: [
            Impact(at: 0, bursts: [Burst(freq: 2900, q: 1.6, decay: 1.3, amp: 0.55)],
                   modes: [Mode(freq: 2450, decay: 9, amp: 0.2), Mode(freq: 2150, decay: 70, amp: 0.05),
                           Mode(freq: 3750, decay: 55, amp: 0.03)]),
            Impact(at: 3, bursts: [Burst(freq: 1600, q: 1.0, decay: 1.8, amp: 0.25)],
                   modes: [Mode(freq: 1000, decay: 10, amp: 0.12)]),
        ],
        brightness: 11000, loudness: 1.1)
}
