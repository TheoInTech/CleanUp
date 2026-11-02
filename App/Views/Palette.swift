import CleanUpCore
import SwiftUI

/// Colors, names and symbols for categories and verdicts, plus the small building blocks (tick
/// circle, icon tile) every screen shares. Depends only on CleanUpCore so the widget can use it too.
enum Palette {
    static let orange = Color(hex: 0xFF9F0A)
    static let blue = Color(hex: 0x0A84FF)
    static let purple = Color(hex: 0xBF5AF2)
    static let green = Color(hex: 0x30D158)
    static let teal = Color(hex: 0x64D2FF)
    static let gray = Color(hex: 0x8E8E93)
    static let red = Color(hex: 0xFF453A)
    static let amber = Color(hex: 0xFFB340)

    /// The ring's remainder and empty ticks.
    static let track = Color.primary.opacity(0.12)

    static func color(_ id: CategoryID) -> Color {
        switch id {
        case .simulators: orange
        case .containers: blue
        case .devServers: purple
        case .apps: green
        case .browserTabs: teal
        case .restart: gray
        }
    }

    static func name(_ id: CategoryID) -> String {
        switch id {
        case .simulators: "Simulators"
        case .containers: "Containers"
        case .devServers: "Dev servers"
        case .apps: "Apps"
        case .browserTabs: "Browser tabs"
        case .restart: "Restart"
        }
    }

    static func symbol(_ id: CategoryID) -> String {
        switch id {
        case .simulators: "iphone"
        case .containers: "shippingbox.fill"
        case .devServers: "server.rack"
        case .apps: "square.grid.2x2.fill"
        case .browserTabs: "globe"
        case .restart: "arrow.clockwise"
        }
    }

    /// Green / amber / red for the menu bar and widget tint.
    static func color(_ mood: Mood) -> Color {
        switch mood {
        case .allGood: green
        case .busy: amber
        case .drainingFast: red
        }
    }

    /// "10.5": cores always with one decimal.
    static func cores(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// "35m", "2h 5m".
    static func minutes(_ value: Int) -> String {
        let value = max(0, value)
        if value < 60 { return "\(value)m" }
        let rest = value % 60
        return rest == 0 ? "\(value / 60)h" : "\(value / 60)h \(rest)m"
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Full / half / empty circle in the category color.
struct TickCircle: View {
    let state: TickState
    let color: Color
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            switch state {
            case .all:
                Circle().fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            case .some:
                Circle().fill(Palette.track)
                Circle().fill(color).mask(alignment: .leading) {
                    Rectangle().frame(width: size / 2)
                }
            case .none:
                Circle().strokeBorder(Palette.gray.opacity(0.7), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .animation(.snappy(duration: 0.2), value: state)
    }
}

/// An SF Symbol on a rounded tile tinted with `color`.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.opacity(0.2))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(color)
            }
    }
}
