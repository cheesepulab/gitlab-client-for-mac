#if DEBUG
import AppKit

/// Debug builds only: GLC_SNAPSHOT=<folder> writes a PNG of every open window after
/// GLC_SNAPSHOT_DELAY seconds (default 4), then quits. GLC_APPEARANCE=dark|light forces a theme.
/// Lets screens be checked without Screen Recording permission.
@MainActor
enum DebugSnapshot {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static func scheduleIfRequested() {
        if let appearance = environment["GLC_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        guard let folder = environment["GLC_SNAPSHOT"] else { return }
        let delay = Double(environment["GLC_SNAPSHOT_DELAY"] ?? "") ?? 4
        // GLC_WINDOW_SIZE=1280x1600 makes the main window taller than the screen, to see a whole page.
        if let size = environment["GLC_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                for window in NSApp.windows where window.isVisible && window.title != "" {
                    window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size[1], width: size[0], height: size[1]), display: true)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = window.title.isEmpty ? "window-\(index)" : window.title.replacingOccurrences(of: "/", with: "-")
                let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            // A sheet can hold up a normal quit; this is a throwaway debug run.
            exit(0)
        }
    }

    static var prefilledDomain: String? { environment["GLC_DEBUG_DOMAIN"] }

    /// GLC_DEBUG_SEED=<url> with GLC_DEBUG_TOKEN=<test token> starts signed in to a mock server,
    /// keeping the token in memory only. GLC_DEBUG_PROJECT=<id>, GLC_DEBUG_TAB=<tab> and
    /// GLC_DEBUG_MR=<iid> then open that screen.
    static func value(_ key: String) -> String? { environment[key] }
    static var opensSettings: Bool { environment["GLC_OPEN_SETTINGS"] != nil }
}
#endif
