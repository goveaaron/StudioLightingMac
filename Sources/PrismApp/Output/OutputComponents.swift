import SwiftUI
import PrismCore

// Shared presentation for outputs: used by the Hardware Test and Settings › Outputs.

extension DMXDeviceState {
    /// Status color: green live, amber waiting, red needs attention.
    var tint: Color {
        switch self {
        case .live: return Theme.success
        case .connecting: return Theme.accent
        case .searching, .unsupported: return Theme.warning
        case .busy, .failed: return Theme.danger
        case .stopped: return Theme.textTertiary
        }
    }
}

extension DMXDeviceSnapshot {
    /// Badge text, e.g. "Live", "Unplugged", "In use by another app".
    var badgeTitle: String { isUnplugged ? "Unplugged" : state.title }
}

extension OutputSummary.Level {
    var tint: Color {
        switch self {
        case .connected: return Theme.success
        case .simulated: return Theme.accent
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }
}

extension DMXDeviceKind {
    var systemImage: String {
        switch self {
        case .enttecPro, .simulated: return "cable.connector.horizontal"
        case .openDMX: return "cable.connector"
        case .artNet, .sACN: return "network"
        }
    }
}

extension OutputDeviceRow {
    /// "Universe 1", "Universes 1–2"; nil when the device sends nothing.
    func universeText(networkUniverses: [Int]) -> String? {
        let list: [Int]
        if snapshot.kind.isNetwork {
            list = networkUniverses
        } else {
            list = universes.filter { $0.key <= max(1, snapshot.portCount) }.sorted { $0.key < $1.key }.map(\.value)
        }
        let text = OutputHealth.universeList(list)
        guard let first = text.first else { return nil }
        return first.uppercased() + text.dropFirst()
    }

    /// "Serial 01234567 · Firmware 1.44 · Universe 1" (USB) or the route (network).
    func identityLine(networkUniverses: [Int]) -> String {
        var parts: [String] = []
        if snapshot.kind.isNetwork {
            if let route = snapshot.path, !route.isEmpty { parts.append(route) }
        } else {
            if let serial = snapshot.serialNumber, !serial.isEmpty { parts.append("Serial \(serial)") }
            if let firmware = snapshot.firmware, !firmware.isEmpty { parts.append("Firmware \(firmware)") }
        }
        if isEnabled, let universe = universeText(networkUniverses: networkUniverses) { parts.append(universe) }
        if !isEnabled { parts.append("Turned off") }
        if parts.isEmpty { parts.append(snapshot.kind.title) }
        return parts.joined(separator: " · ")
    }
}

/// One output device: name, identity, state and what to do about it.
struct OutputDeviceCard: View {
    let row: OutputDeviceRow
    var networkUniverses: [Int] = [1]
    /// Show the state's explanation when the device isn't live.
    var showsMessage = true

    var body: some View {
        let s = row.snapshot
        let tint = row.isEnabled ? s.state.tint : Theme.textTertiary
        HStack(alignment: .top, spacing: Theme.Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(tint.opacity(0.14))
                Image(systemName: s.kind.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text(s.name)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    StatusPill(text: row.isEnabled ? s.badgeTitle : "Off", color: tint, pulsing: s.state == .live)
                }
                Text(row.identityLine(networkUniverses: networkUniverses))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if showsMessage, row.isEnabled, s.state != .live {
                    Text(s.message)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = s.warning, row.isEnabled {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).fill(Theme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// A numbered or bulleted line of guidance.
struct GuidanceRow: View {
    var number: Int?
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            if let number {
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.control))
            } else {
                Text("•")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18)
            }
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Title and one-line explanation at the top of a step or section.
struct StepIntro: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
