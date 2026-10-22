import AppKit
import SwiftUI

enum AppLinks {
    static let billingConsoleURL = URL(string: "https://www.autodl.com/console/bill")!

    static func openBillingConsole() {
        NSWorkspace.shared.open(billingConsoleURL)
    }
}

enum AppTime {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone.current

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()
}

enum AppTheme {
    static let mint = Color(red: 0.36, green: 0.86, blue: 0.56)
    static let aqua = Color(red: 0.42, green: 0.65, blue: 0.90)
    static let violet = Color(red: 0.62, green: 0.58, blue: 0.86)
    static let amber = Color(red: 0.92, green: 0.70, blue: 0.36)
    static let rose = Color(red: 0.90, green: 0.45, blue: 0.47)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.68)
    static let textTertiary = Color.white.opacity(0.50)

    static let pageBackground = Color(red: 0.047, green: 0.051, blue: 0.059)
    static let panelBackground = Color(red: 0.067, green: 0.071, blue: 0.082)
    static let border = Color.white.opacity(0.11)
}

extension InstanceState {
    var tint: Color {
        switch self {
        case .running: return AppTheme.mint
        case .stopped: return Color.white.opacity(0.48)
        case .starting: return AppTheme.amber
        case .stopping: return AppTheme.rose
        case .unknown: return AppTheme.violet
        }
    }
}

/// What a no-card boot request turned out to be, judged from the instance as AutoDL now reports it.
enum NoCardBootCheck: Equatable {
    /// Not up yet, or `start_mode` not reported: keep waiting.
    case pending
    /// Running as `non_gpu`.
    case confirmed
    /// Running as `gpu`: the request was not honoured and the instance bills as a GPU instance.
    case mismatch
}

extension AutoDLInstance {
    var noCardBootCheck: NoCardBootCheck {
        // While starting, start_mode can still hold the previous boot's value, so only a running instance counts.
        guard state == .running else { return .pending }
        switch startMode.lowercased() {
        case "non_gpu": return .confirmed
        case "gpu": return .mismatch
        default: return .pending
        }
    }

    /// Running, but booted without a GPU: it holds no card and bills at the cheaper no-card rate.
    var isNoCardMode: Bool { state == .running && startMode.lowercased() == "non_gpu" }
    /// Running and occupying a card.
    var holdsGPU: Bool { state == .running && !isNoCardMode }
    var statusLabel: String { isNoCardMode ? "无卡运行" : state.label }
    var statusTint: Color { isNoCardMode ? AppTheme.aqua : state.tint }
}

extension ActivityKind {
    var tint: Color {
        switch self {
        case .info: return AppTheme.aqua
        case .success: return AppTheme.mint
        case .warning: return AppTheme.amber
        case .error: return AppTheme.rose
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isOpaque = true
        window.backgroundColor = NSColor(AppTheme.pageBackground)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 1_180, height: 720)
    }
}

extension View {
    func panel(cornerRadius: CGFloat = 12) -> some View {
        // v2: terminal look, so every panel is nearly square regardless of what the call site asks for.
        let shape = RoundedRectangle(cornerRadius: min(cornerRadius, 4), style: .continuous)
        return background(AppTheme.panelBackground, in: shape)
            .overlay {
                shape.strokeBorder(AppTheme.border, lineWidth: 1)
            }
    }
}

enum AppBrand {
    static let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "BrandIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage ?? NSImage(size: NSSize(width: 512, height: 512))
    }()
}

struct BrandMark: View {
    var size: CGFloat = 42

    var body: some View {
        Image(nsImage: AppBrand.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("胡闹AutoDL")
    }
}

struct StatusPill: View {
    let label: String
    let tint: Color
    var showsDot = true

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Text("●")
                    .scaledFont(size: 8)
                    .foregroundStyle(tint)
            }
            Text(label)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(tint.opacity(0.95))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(tint.opacity(0.32), lineWidth: 1)
        }
    }
}

struct IconButton: View {
    let symbol: String
    let action: () -> Void
    var isActive = false
    var help: String = ""

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(isActive ? AppTheme.mint : AppTheme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .background(
                    hovered ? Color.white.opacity(0.06) : AppTheme.panelBackground,
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(AppTheme.border, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var appFontScale: CGFloat {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.appFontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        // v2: nothing below 10pt; the old 8-9pt captions were hard to read on dark glass.
        content.font(.system(size: max(size, 10) * scale, weight: weight, design: design == .default ? .monospaced : design))
    }
}

extension View {
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }
}

struct ActionButtonStyle: ButtonStyle {
    var tint: Color = .white
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return configuration.label
            .scaledFont(size: 12, weight: .medium)
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(prominent ? tint : tint.opacity(0.06), in: shape)
            .overlay {
                if !prominent {
                    shape.strokeBorder(tint.opacity(0.40), lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct CustomSwitch: View {
    let isOn: Bool
    var tint: Color = AppTheme.mint
    let action: () -> Void

    // Drawn in SwiftUI: the system .switch style hosts an NSSwitch, which is slow to build on every page switch.
    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? tint : Color.white.opacity(0.14))
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("自动开机")
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityAddTraits(.isToggle)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .scaledFont(size: 28, weight: .light)
                .foregroundStyle(AppTheme.textSecondary)
            Text(title)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(message)
                .scaledFont(size: 12)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

enum AppFormat {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    static let billDayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = AppTime.timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static let billDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = AppTime.timeZone
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static let chartDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = AppTime.timeZone
        formatter.dateFormat = "M/d"
        return formatter
    }()

    static let releaseDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = AppTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let releaseShort: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = AppTime.timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    static func relative(_ date: Date?) -> String {
        guard let date else { return "尚未同步" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟前" }
        return time.string(from: date)
    }

    static func storage(_ bytes: Int64) -> String {
        let gib = Double(max(0, bytes)) / 1_073_741_824
        if gib >= 1024 {
            return String(format: "%.2f TB", gib / 1024)
        }
        if gib >= 100 {
            return String(format: "%.0f GB", gib)
        }
        return String(format: "%.1f GB", gib)
    }
}


/// Section frame with a prompt-style title row: `▍ TITLE ........ trailing`.
struct TermSection<Content: View, Trailing: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content

    init(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("▍")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(AppTheme.mint)
                Text(title)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14)
            .frame(height: 34)

            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)

            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .panel()
    }
}

/// Block-character meter, e.g. `████████░░░░░░░░`.
struct AsciiBar: View {
    let fraction: Double
    var cells = 20
    var tint: Color = AppTheme.mint
    var size: CGFloat = 12

    var body: some View {
        let clamped = max(0, min(fraction, 1))
        let filled = Int((clamped * Double(cells)).rounded())
        (Text(String(repeating: "█", count: filled)).foregroundStyle(tint)
            + Text(String(repeating: "░", count: max(cells - filled, 0))).foregroundStyle(Color.white.opacity(0.13)))
            .scaledFont(size: size)
            .lineLimit(1)
            .fixedSize()
    }
}
