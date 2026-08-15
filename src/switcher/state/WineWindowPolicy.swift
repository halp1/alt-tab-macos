import Cocoa

/// Pure kernel for Wine-backed windows — the one class of window AltTab accepts ABOVE the normal window
/// level. Wine wrappers (CrossOver, Yaagl, Whisky, Wineskin, plain Wine) host Windows apps in processes
/// that carry no bundle id, hand every window role `AXWindow` / subrole `AXUnknown`, and raise a
/// screen-covering game window over the Dock / menu-bar band. See `WineWindowPolicySpecs.md`.
enum WineWindowPolicy {
    /// Wine's macdrv raises a screen-covering game window above the Dock and the menu bar so the game can
    /// cover them; such a window is NEVER at level 0. MEASURED live on macOS 26.5, CrossOver 26.3
    /// ("Geometry Dash") and Yaagl ("Genshin Impact"): level 27 while the game holds focus, level 21 once
    /// Wine minimizes it on focus loss — one above the Dock (20), two above the status band (25). Wine's
    /// popup menus and tooltips sit at 101+, so this ceiling admits the game window without them.
    static let maxLevel = CGWindowLevelForKey(.statusWindow) + 2

    /// Restated here rather than reused from `CGWindow`, which is app-target only: this kernel is compiled
    /// into `unit-tests` too, so it must not reach outside the pure layer.
    static let normalLevel = CGWindowLevelForKey(.normalWindow)

    /// Levels a Wine window may be accepted at: normal, plus the raised band above.
    static func isAcceptableLevel(_ level: CGWindowLevel) -> Bool {
        return level >= normalLevel && level <= maxLevel
    }

    /// Cheap snapshot-only pre-check, so a caller pays for a process-identity lookup only for a window that
    /// could plausibly be a raised Wine game window. Wine's helper windows — the 1512x33 menu-bar proxies and
    /// the 500x500 desktop stand-in it creates per process — are untitled, so the title carries this gate.
    static func hasRaisedGameWindowShape(_ level: CGWindowLevel, _ title: String) -> Bool {
        return level > normalLevel && isAcceptableLevel(level) && !title.isEmpty
    }

    /// Is this process running Windows code under Wine? The executable path is the only stable signal: the
    /// process carries no bundle id, and its name is the Windows binary's ("GeometryDash.exe") under
    /// CrossOver but the loader's ("wine") under Yaagl, so neither name alone generalizes.
    static func isWineProcess(_ bundleIdentifier: String?, _ executablePath: String?, _ localizedName: String?) -> Bool {
        guard bundleIdentifier == nil else { return false }
        return isWineExecutablePath(executablePath) || loaderNames.contains(localizedName ?? "")
    }

    static func isWineExecutablePath(_ executablePath: String?) -> Bool {
        guard let executablePath else { return false }
        return executablePath.range(of: executablePattern, options: .regularExpression) != nil
    }

    /// `/winetemp-` is CrossOver's per-bottle temp copy of the bottle's binaries
    /// (`…/T/winetemp-<id>/GeometryDash.exe`); `/wine/` a Wine tree, which is what the loader runs from when
    /// the wrapper doesn't copy (Yaagl's `…/Yaagl OS/wine/lib/wine/x86_64-unix/wine`, Wineskin's
    /// `…/SharedSupport/wine/bin/wine`); the trailing alternative the loader binaries themselves, for a
    /// wrapper that keeps them elsewhere (Whisky's `…/Libraries/Wine/bin/wine64`).
    private static let executablePattern = "(/winetemp-|/wine/|/wine(64)?(-preloader|loader|server)?$)"

    /// Name fallback for the pre-2023 CrossOver shape, whose process name was the loader's.
    private static let loaderNames: Set<String> = ["wine", "wine64", "wineloader", "wine-preloader", "wine64-preloader"]

    /// Would capturing this window right now return a blank frame? A Wine game renders through a GPU surface
    /// that goes away when the WindowServer orders the window out, leaving nothing to screenshot. MEASURED on
    /// macOS 26.5: ordered out, ScreenCaptureKit hands back a single flat colour — opaque #1E1E1E for Genshin
    /// Impact, fully transparent for Geometry Dash — while the same window on screen captures perfectly (3232
    /// distinct colours sampled). A native app does NOT behave this way: a minimized TextEdit window still
    /// captures its real content, because macOS keeps its backing store.
    ///
    /// This matters more than the rarity suggests, because Wine MINIMIZES a fullscreen game the moment it
    /// loses focus — which is exactly what summoning the switcher does. Capturing anyway would overwrite the
    /// good thumbnail with the blank one on every single show, so the tile would be permanently blank.
    ///
    /// So content is live in exactly one state: the game is the FOCUSED window of the FRONTMOST app, and the
    /// switcher is not up. Anything less is blank — verified live, and the weaker tests are not enough:
    ///   - `isMinimized` is never set for it. An order-out is ambiguous (minimize / hide / other-Space /
    ///     closing), so the reducer only records the wid in `carried.offScreen`; the live log shows
    ///     `windowOrderedOut #2276` and `unminimized #2276`, never `minimized`.
    ///   - The WindowServer's ordered-in bit is not enough either. Restoring the game flickers it ordered-in
    ///     before Wine has drawn (measured: an order-in/order-out pair 300ms apart), and a capture taken in
    ///     that gap comes back blank while every state bit says the window is up.
    static func yieldsBlankCapture(isSwitcherActive: Bool, isFrontmostApp: Bool, isFocusedWindow: Bool) -> Bool {
        return isSwitcherActive || !isFrontmostApp || !isFocusedWindow
    }
}
