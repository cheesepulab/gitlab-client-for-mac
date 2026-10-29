import SwiftUI
import GitLabClientCore

/// Status colors. System colors already adapt to light and dark mode.
enum Tone {
    case green, orange, red, blue, purple, gray

    var color: Color {
        switch self {
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .blue: return .accentColor
        case .purple: return .purple
        case .gray: return .secondary
        }
    }
}

struct Pill: View {
    let text: String
    var tone: Tone = .gray

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone == .gray ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.color.opacity(tone == .gray ? 0.12 : 0.15), in: Capsule())
    }
}

/// Rounded square with a domain's two letters, as in the domain switcher.
struct Monogram: View {
    let text: String
    var color: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct InitialsAvatar: View {
    let initials: String
    var size: CGFloat = 40
    var tint: Color = .accentColor

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}

extension GitLabDomain {
    /// Stable color per domain for its monogram.
    var tint: Color {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green]
        let sum = key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}

extension GitLabPerson {
    /// Stable avatar color per user.
    var tint: Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
        let sum = username.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}

/// "38 s", "2 min 40 s", "1 h 5 min".
func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total) s" }
    if total < 3600 { return "\(total / 60) min \(String(format: "%02d", total % 60)) s" }
    return "\(total / 3600) h \(total % 3600 / 60) min"
}

/// One row of a checklist: icon, title, detail.
struct CheckRow: View {
    let title: String
    let state: CheckState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                if let detail = state.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .pending: ProgressView().controlSize(.small)
        case .passed: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(.red)
        }
    }
}

/// Bordered group; callers put a Divider between rows.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Label/value grid row inside a Card, as in the Connected and Settings → Domains screens.
struct DetailRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct ScopeChips: View {
    let scopes: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(scopes, id: \.self) { scope in
                Text(scope)
                    .font(.caption.monospaced())
                    .foregroundStyle(scope == "api" ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((scope == "api" ? Color.accentColor : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

struct ErrorText: View {
    let message: String

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.octagon").foregroundStyle(.red)
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}

extension TokenInfo {
    var expiryText: String {
        guard let date = expiryDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

extension View {
    /// Primary-ish button for footers.
    func footerBar() -> some View {
        padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }
}

enum Clipboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

func relative(_ date: Date?) -> String {
    guard let date else { return "" }
    return date.formatted(.relative(presentation: .named))
}
