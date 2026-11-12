import SwiftUI

extension Color {
    static let clacky = Color(hex: 0xEE6A3A)

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The drop-down panel under the menu bar icon.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var updater: Updater

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _updater = ObservedObject(wrappedValue: model.updater)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.needsPermission { permissionCard }
            if updater.showsBanner { updateCard }

            section("Switch") {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(RecordedSwitch.all) { rec in
                        let id = "rec:\(rec.id)"
                        Tile(title: rec.shortName, subtitle: rec.kind, selected: model.sourceID == id) {
                            model.select(id)
                        } glyph: {
                            StemGlyph(stem: Stem(for: rec.id), color: Color(hex: rec.color))
                        }
                        .help(rec.name)
                    }
                }
            }

            section("Sound packs", accessory: {
                Button("Find more") { model.findPacks() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.clacky)
            }) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(model.packs, id: \.folder) { pack in
                        Tile(title: pack.name, subtitle: "Sound pack", selected: model.sourceID == pack.sourceID) {
                            model.select(pack.sourceID)
                        } glyph: {
                            Housing { Image(systemName: "waveform").font(.system(size: 10, weight: .semibold)) }
                        }
                        .help(pack.name)
                        .contextMenu {
                            Button("Remove Pack") { model.removePack(pack) }
                        }
                    }
                    ImportTile { model.importPack() }
                }
            }

            controls
            footer
        }
        .padding(14)
        .frame(width: 340)
        .tint(.clacky)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: model.enabled ? [Color(hex: 0xF68C5E), Color(hex: 0xD9542A)]
                            : [Color(hex: 0x9A9AA0), Color(hex: 0x76767C)],
                        startPoint: .top, endPoint: .bottom))
                Image(nsImage: Icons.keycap(active: true))
                    .renderingMode(.template)
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Clacky").font(.system(size: 13.5, weight: .semibold))
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("Clacky", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("Turn Clacky on or off. You can also ⌥-click the menu bar icon.")
        }
    }

    private var statusLine: String {
        if !model.enabled { return "Off" }
        if model.needsPermission { return "Waiting for Input Monitoring" }
        return model.currentTitle
    }

    private var permissionCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 15))
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.needsRelaunch ? "Almost there" : "Allow Input Monitoring")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.needsRelaunch
                        ? "Relaunch Clacky to finish turning on Input Monitoring."
                        : "Clacky needs this to hear key presses. It never records what you type.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(model.needsRelaunch ? "Relaunch Clacky" : "Open System Settings") {
                    model.needsRelaunch ? model.relaunch() : model.openInputMonitoring()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    // MARK: - Updates

    private var updateCard: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                switch updater.status {
                case .checking, .downloading, .installing, .restarting:
                    ProgressView().controlSize(.small)
                case .upToDate:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                default:
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.clacky)
                }
            }
            .font(.system(size: 15))
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(updateTitle).font(.system(size: 12, weight: .semibold))
                Text(updateDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            switch updater.status {
            case .waitingToRestart:
                Button("Restart") { updater.restartNow() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .manualUpdateNeeded(_, let page):
                Button("Download") { model.dismissPanel?(); NSWorkspace.shared.open(page) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .failed:
                Button("Try Again") { updater.checkNow() }
                    .controlSize(.small)
            default:
                EmptyView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(updateTint.opacity(0.12)))
    }

    private var updateTitle: String {
        switch updater.status {
        case .checking: return "Checking for updates"
        case .upToDate: return "Clacky is up to date"
        case .downloading(let v), .installing(let v), .restarting(let v): return "Updating to \(v)"
        case .waitingToRestart(let v): return "Clacky \(v) is ready"
        case .manualUpdateNeeded(let v, _): return "Clacky \(v) is available"
        case .failed: return "Couldn't update"
        case .idle: return ""
        }
    }

    private var updateDetail: String {
        switch updater.status {
        case .upToDate: return "You have the latest version, \(updater.currentVersion)."
        case .waitingToRestart: return "It restarts when you close this panel."
        case .manualUpdateNeeded: return "Move Clacky to Applications to get updates automatically."
        case .failed(let message): return message.replacingOccurrences(of: "Update failed: ", with: "")
        default: return updater.statusText
        }
    }

    private var updateTint: Color {
        switch updater.status {
        case .upToDate: return .green
        case .failed: return .orange
        default: return .clacky
        }
    }

    // MARK: - Settings

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Slider(value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }),
                       in: 0...1) { editing in
                    if !editing { model.playTestClick() }
                }
                .controlSize(.small)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if model.macMuted {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .frame(width: 18)
                    Text("Your Mac is muted, which silences every app, Clacky included.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            Divider().padding(.leading, 38)
            ToggleRow(symbol: "dial.medium", title: "Steady volume",
                      detail: "Holds level as Mac volume changes", isOn: $model.steadyVolume)
            Divider().padding(.leading, 38)
            ToggleRow(symbol: "headphones", title: "Spatial audio",
                      detail: "Each key plays from where it sits", isOn: $model.spatial)
            Divider().padding(.leading, 38)
            ToggleRow(symbol: "arrow.uturn.up", title: "Release sounds",
                      detail: "Keys click on the way back up too", isOn: $model.releaseSounds)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                     set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11))

            Spacer()

            Menu {
                Text("Clacky \(updater.currentVersion)")
                Button("Check for Updates") { updater.checkNow() }
                    .disabled(updater.isBusy)
                Toggle("Update Automatically", isOn: $updater.automaticallyChecks)
                Divider()
                Button("About Clacky") { model.showAbout() }
                Button("Clacky on GitHub") { model.openGitHub() }
                Divider()
                Button("Show Packs Folder") { model.showPacksFolder() }
                Button("Find Sound Packs Online") { model.findPacks() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(.secondary)
            .overlay(alignment: .topTrailing) {
                if updater.needsAttention {
                    Circle().fill(Color.clacky).frame(width: 7, height: 7).offset(x: 2, y: -2)
                }
            }
            .help(updater.needsAttention ? "An update is ready" : "More")

            Button { model.quit() } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit Clacky")
        }
        .foregroundStyle(.secondary)
    }

    private func section<Content: View, Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            content()
        }
    }
}

// MARK: - Pieces

private struct Tile<Glyph: View>: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TileLayout(title: title, subtitle: subtitle, glyph: glyph)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? Color.clacky : Color.primary.opacity(0.07),
                                      lineWidth: selected ? 1.5 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private var fill: Color {
        selected ? Color.clacky.opacity(0.16) : Color.primary.opacity(hovering ? 0.09 : 0.045)
    }
}

private struct ImportTile: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TileLayout(title: "Import…", subtitle: "Mechvibes pack") {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(.secondary)
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 22, height: 22)
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.primary.opacity(0.2)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Import a Mechvibes sound pack (.zip or folder)")
    }
}

private struct TileLayout<Glyph: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            glyph()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToggleRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// A switch housing seen from above.
private struct Housing<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.08))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            content().foregroundStyle(.secondary)
        }
        .frame(width: 22, height: 22)
    }
}

enum Stem {
    case cross, box, alps, round, spring

    init(for id: String) {
        switch id {
        case "box-navy": self = .box
        case "alps-blue": self = .alps
        case "topre": self = .round
        case "buckling-spring": self = .spring
        default: self = .cross
        }
    }
}

/// The switch's stem in its colour: MX cross, Box, Alps slider, Topre dome or a spring.
private struct StemGlyph: View {
    let stem: Stem
    let color: Color

    var body: some View {
        Housing {
            shape
                .fill(color, style: FillStyle(eoFill: true))
                .overlay(shape.stroke(Color.primary.opacity(0.28), lineWidth: 0.5))
        }
    }

    private var shape: AnyShape {
        switch stem {
        case .cross: return AnyShape(CrossShape(arm: 6.5, width: 2.2))
        case .box: return AnyShape(BoxStemShape())
        case .alps: return AnyShape(RoundedRectangle(cornerRadius: 1.5).inset(by: 0).size(width: 11, height: 7)
                .offset(x: 5.5, y: 7.5))
        case .round: return AnyShape(Circle().inset(by: 5))
        case .spring: return AnyShape(SpringShape())
        }
    }
}

private struct CrossShape: Shape {
    var arm: CGFloat
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        let x = rect.midX, y = rect.midY, a = arm, w = width
        var p = Path()
        p.addLines([
            CGPoint(x: x - w, y: y - a), CGPoint(x: x + w, y: y - a), CGPoint(x: x + w, y: y - w),
            CGPoint(x: x + a, y: y - w), CGPoint(x: x + a, y: y + w), CGPoint(x: x + w, y: y + w),
            CGPoint(x: x + w, y: y + a), CGPoint(x: x - w, y: y + a), CGPoint(x: x - w, y: y + w),
            CGPoint(x: x - a, y: y + w), CGPoint(x: x - a, y: y - w), CGPoint(x: x - w, y: y - w),
        ])
        p.closeSubpath()
        return p
    }
}

/// Kailh Box: a square box around a smaller cross (filled even-odd, so the box is a ring).
private struct BoxStemShape: Shape {
    func path(in rect: CGRect) -> Path {
        let x = rect.midX, y = rect.midY
        var p = Path()
        p.addRoundedRect(in: CGRect(x: x - 7, y: y - 7, width: 14, height: 14), cornerSize: CGSize(width: 2, height: 2))
        p.addRoundedRect(in: CGRect(x: x - 5, y: y - 5, width: 10, height: 10), cornerSize: CGSize(width: 1, height: 1))
        p.addPath(CrossShape(arm: 4, width: 1.4).path(in: rect))
        return p
    }
}

private struct SpringShape: Shape {
    func path(in rect: CGRect) -> Path {
        // A short coil drawn as stacked ellipses, filled as one outline.
        var p = Path()
        let turns = 4, width: CGFloat = 12, height: CGFloat = 3.2
        let top = rect.midY - CGFloat(turns) * height / 2 - 0.5
        for i in 0..<turns {
            p.addEllipse(in: CGRect(x: rect.midX - width / 2, y: top + CGFloat(i) * (height + 0.3),
                                    width: width, height: height))
        }
        return p
    }
}
