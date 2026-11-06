import SwiftUI

extension HealthLevel {
    var color: Color {
        switch self {
        case .ok: return .green
        case .unknown: return .gray
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .ok: return "externaldrive.badge.checkmark"
        case .unknown: return "externaldrive.badge.questionmark"
        case .warning: return "externaldrive.badge.exclamationmark"
        case .critical: return "externaldrive.badge.xmark"
        }
    }
}

extension DriveHealth {
    func tempColor(_ config: NASConfig) -> Color {
        guard let t = temperature else { return .secondary }
        let (warn, crit) = kind.isSolidState ? (config.ssdWarn, config.ssdCrit) : (config.hddWarn, config.hddCrit)
        if t >= crit { return .red }
        if t >= warn { return .orange }
        return .secondary
    }

    var tempText: String { temperature.map { "\(Int($0.rounded()))°" } ?? "–" }
}

/// One compact line per drive, used by the widget and the menu bar popover.
struct DriveRow: View {
    let drive: DriveHealth
    let config: NASConfig
    var showModel = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(drive.level.color).frame(width: 7, height: 7)
            Text(drive.name)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .lineLimit(1)
            Text(drive.kind.label)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            if showModel {
                Text(drive.model.isEmpty ? drive.sizeText : "\(drive.model) · \(drive.sizeText)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if drive.totalErrors > 0 {
                Text("\(drive.totalErrors) err")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            }
            Text(drive.tempText)
                .font(.system(.caption, design: .rounded).monospacedDigit())
                .foregroundStyle(drive.tempColor(config))
        }
    }
}
