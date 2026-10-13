import XCTest

/// Pins `WineWindowPolicy` against the shapes measured live on macOS 26.5 from CrossOver 26.3
/// ("Geometry Dash") and Yaagl ("Genshin Impact") — see `WineWindowPolicySpecs.md` for the capture.
/// Pure data in, `Bool` out. `PhysicalSurface.resolveWineGameWindow` applies these verdicts at the admission
/// gate, `WindowThumbnails.yieldsBlankCapture` at the capture gate.
///
/// Groups: A measured level constants · B acceptable levels · C raised-shape pre-check ·
/// D executable-path identity · E full process identity (bundle id + name fallback) ·
/// F the real-world windows this was written for.
final class WineWindowPolicyTests: XCTestCase {

    // MARK: - A. The measured level constants

    /// Wine raises a game window two above the status band; 27 is the ceiling both games were seen at.
    func testMaxLevelIsTwoAboveStatusWindow() {
        XCTAssertEqual(WineWindowPolicy.maxLevel, CGWindowLevelForKey(.statusWindow) + 2)
        XCTAssertEqual(WineWindowPolicy.maxLevel, 27)
    }

    /// The two levels actually measured: 27 focused, 21 minimized-on-focus-loss.
    func testBothMeasuredGameLevelsAreAcceptable() {
        XCTAssertTrue(WineWindowPolicy.isAcceptableLevel(27))
        XCTAssertTrue(WineWindowPolicy.isAcceptableLevel(21))
    }

    // MARK: - B. Acceptable levels

    func testNormalLevelIsAcceptable() {
        XCTAssertTrue(WineWindowPolicy.isAcceptableLevel(WineWindowPolicy.normalLevel))
    }

    /// Wine's own menus and tooltips live at popUpMenu (101) and above; they must stay out.
    func testPopUpMenuLevelIsNotAcceptable() {
        XCTAssertFalse(WineWindowPolicy.isAcceptableLevel(CGWindowLevelForKey(.popUpMenuWindow)))
        XCTAssertFalse(WineWindowPolicy.isAcceptableLevel(WineWindowPolicy.maxLevel + 1))
    }

    /// The wallpaper and desktop icons sit far below 0 and are not windows.
    func testNegativeLevelsAreNotAcceptable() {
        XCTAssertFalse(WineWindowPolicy.isAcceptableLevel(-1))
        XCTAssertFalse(WineWindowPolicy.isAcceptableLevel(CGWindowLevelForKey(.desktopWindow)))
    }

    // MARK: - C. The raised-shape pre-check (an optimization gate, not the verdict)

    func testRaisedShapeAcceptsATitledGameWindowAtBothMeasuredLevels() {
        XCTAssertTrue(WineWindowPolicy.hasRaisedGameWindowShape(27, "Genshin Impact"))
        XCTAssertTrue(WineWindowPolicy.hasRaisedGameWindowShape(21, "Geometry Dash"))
    }

    /// Level 0 is the coarse gate's own business; this pre-check only covers the RAISED band, so it must
    /// not claim a normal-level window (which needs no process lookup to get through).
    func testRaisedShapeRejectsNormalLevel() {
        XCTAssertFalse(WineWindowPolicy.hasRaisedGameWindowShape(WineWindowPolicy.normalLevel, "Genshin Impact"))
    }

    /// Wine's helper windows (menu-bar proxy, desktop stand-in) are untitled — this is what keeps them
    /// from ever reaching the process lookup.
    func testRaisedShapeRejectsUntitledWindows() {
        XCTAssertFalse(WineWindowPolicy.hasRaisedGameWindowShape(27, ""))
    }

    /// The admission gate keys on level alone, because a batched WindowServer query returns "" for every
    /// title. The game must be recognised at both measured levels with no title at all — this is the exact
    /// regression that made it flicker out of the switcher mid-session and become a windowless icon.
    func testRaisedLevelIsRecognizedWithoutATitle() {
        XCTAssertTrue(WineWindowPolicy.isRaisedGameWindowLevel(27))
        XCTAssertTrue(WineWindowPolicy.isRaisedGameWindowLevel(21))
    }

    /// Wine's helper windows (menu-bar proxy, desktop stand-in) sit at level 0, so the raised band excludes
    /// them without needing the title that the batched query cannot supply.
    func testWineHelperWindowsAreExcludedByLevelAlone() {
        XCTAssertFalse(WineWindowPolicy.isRaisedGameWindowLevel(WineWindowPolicy.normalLevel))
        XCTAssertFalse(WineWindowPolicy.isRaisedGameWindowLevel(CGWindowLevelForKey(.popUpMenuWindow)))
    }

    func testRaisedShapeRejectsLevelsAboveTheCeiling() {
        XCTAssertFalse(WineWindowPolicy.hasRaisedGameWindowShape(101, "some menu"))
    }

    // MARK: - D. Executable-path identity

    /// CrossOver copies the bottle's binaries to a per-bottle temp dir and runs them by their Windows name.
    func testCrossOverBottleTempPathIsWine() {
        XCTAssertTrue(WineWindowPolicy.isWineExecutablePath(
            "/private/var/folders/_8/g635xwbj46141qbl7vlhc0ww0000gn/T//winetemp-6708606-33568-1784110844-0/GeometryDash.exe"))
    }

    /// Yaagl runs the loader itself, out of its own Wine tree.
    func testYaaglWineTreePathIsWine() {
        XCTAssertTrue(WineWindowPolicy.isWineExecutablePath(
            "/Users/halp/Library/Application Support/Yaagl OS/wine/lib/wine/x86_64-unix/wine"))
    }

    func testCrossOverOwnWineTreePathIsWine() {
        XCTAssertTrue(WineWindowPolicy.isWineExecutablePath(
            "/Users/halp/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine"))
    }

    /// Whisky keeps the loader outside any `/wine/` directory, so the loader basename has to carry it.
    func testWhiskyLoaderBasenameIsWine() {
        XCTAssertTrue(WineWindowPolicy.isWineExecutablePath(
            "/Users/x/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64"))
    }

    func testLoaderBasenamesAreWine() {
        for path in ["/usr/local/bin/wine", "/opt/homebrew/bin/wine64", "/tmp/winetemp-1/wineloader",
                     "/usr/local/bin/wine-preloader", "/usr/local/bin/wine64-preloader", "/usr/local/bin/wineserver"] {
            XCTAssertTrue(WineWindowPolicy.isWineExecutablePath(path), path)
        }
    }

    func testUnrelatedPathsAreNotWine() {
        for path in ["/Applications/Discord.app/Contents/MacOS/Discord",
                     "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
                     "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
                     "/Applications/Winery.app/Contents/MacOS/Winery",
                     "/Applications/Yaagl OS.app/Contents/MacOS/Yaagl"] {
            XCTAssertFalse(WineWindowPolicy.isWineExecutablePath(path), path)
        }
    }

    func testNilPathIsNotWine() {
        XCTAssertFalse(WineWindowPolicy.isWineExecutablePath(nil))
    }

    // MARK: - E. Full process identity

    /// A bundle id means a native app, whatever its path looks like.
    func testProcessWithABundleIdIsNeverWine() {
        XCTAssertFalse(WineWindowPolicy.isWineProcess("com.3shain.yaagl.os",
            "/Users/x/Library/Application Support/Yaagl OS/wine/lib/wine/x86_64-unix/wine", "Yaagl"))
    }

    /// The Yaagl launcher is a native app; only the game it launches needed this rule.
    func testYaaglLauncherItselfIsNotWine() {
        XCTAssertFalse(WineWindowPolicy.isWineProcess("com.3shain.yaagl.os",
            "/Applications/Yaagl OS.app/Contents/MacOS/Yaagl", "Yaagl OS"))
    }

    /// The pre-2023 CrossOver shape, which the original rule keyed on, still resolves via the name fallback.
    func testLegacyPreloaderNameIsWineWhenPathMisses() {
        XCTAssertTrue(WineWindowPolicy.isWineProcess(nil, "/some/opaque/path", "wine64-preloader"))
    }

    // MARK: - E2. The CrossOver bottle-app launcher shape

    private static let bottleAppPath = "/Users/halp/Applications/CrossOver/GeometryDash.app/Contents/MacOS/Menu Helper"
    private static let bottleAppBundleId = "com.codeweavers.CrossOverHelper.4DB4563826BAD0EB2F60EE6E42D0EA4B.3994D592B8B19BDF44EBB71B0F8A6B3A"

    /// Launched from its bottle app rather than through Steam, the game's window is owned by CrossOver's
    /// `Menu Helper`, which HAS a bundle id and a path containing neither `/wine/` nor `/winetemp-`. Measured
    /// live: pid 46809, wid 84840, level 27, title "Geometry Dash".
    func testCrossOverBottleAppLauncherIsWine() {
        XCTAssertTrue(WineWindowPolicy.isCrossOverBottleApp(Self.bottleAppBundleId, Self.bottleAppPath))
        XCTAssertTrue(WineWindowPolicy.isWineProcess(Self.bottleAppBundleId, Self.bottleAppPath, "GeometryDash"))
    }

    /// Neither half of the loader rule can see it: the path misses the pattern, and the bundle id is not nil.
    func testBottleAppLauncherIsMissedByTheLoaderRule() {
        XCTAssertFalse(WineWindowPolicy.isWineExecutablePath(Self.bottleAppPath))
    }

    /// Every bottle entry shares the shape, so the rule generalizes rather than naming one game.
    func testEveryCrossOverBottleEntryIsRecognized() {
        for (id, path) in [("com.codeweavers.CrossOverHelper.F3C1C17BD4C741943BFDBB6C48C87F49.C9714D92416DB196B9495DA9D96E2843",
                            "/Users/halp/Applications/CrossOver/Epic Games Launcher.app/Contents/MacOS/Menu Helper"),
                           ("com.codeweavers.CrossOverHelper.C71B4244F70372F8BE07A3E83C584900.8C07343CF92C0B4C498BA961C4525066",
                            "/Users/halp/Applications/CrossOver/EA/EA.app/Contents/MacOS/Menu Helper")] {
            XCTAssertTrue(WineWindowPolicy.isCrossOverBottleApp(id, path), id)
        }
    }

    /// Both halves are required, so neither a CodeWeavers bundle id alone nor a `Menu Helper` path alone
    /// admits a process — CrossOver's own app stays a native app.
    func testCrossOverItselfAndPartialMatchesAreNotBottleApps() {
        XCTAssertFalse(WineWindowPolicy.isCrossOverBottleApp("com.codeweavers.CrossOver",
            "/Users/halp/Applications/CrossOver.app/Contents/MacOS/CrossOver"))
        XCTAssertFalse(WineWindowPolicy.isCrossOverBottleApp(Self.bottleAppBundleId, "/Applications/Other.app/Contents/MacOS/Other"))
        XCTAssertFalse(WineWindowPolicy.isCrossOverBottleApp("com.example.app", Self.bottleAppPath))
        XCTAssertFalse(WineWindowPolicy.isCrossOverBottleApp(nil, Self.bottleAppPath))
    }

    func testUnknownBundleLessProcessIsNotWine() {
        XCTAssertFalse(WineWindowPolicy.isWineProcess(nil, "/usr/libexec/GamePolicyAgent", "GamePolicyAgent"))
        XCTAssertFalse(WineWindowPolicy.isWineProcess(nil, nil, nil))
    }

    // MARK: - F. The real-world windows this was written for

    /// Genshin Impact under Yaagl: raised level, titled, loader path, no bundle id.
    func testGenshinImpactUnderYaaglIsRecognized() {
        let path = "/Users/halp/Library/Application Support/Yaagl OS/wine/lib/wine/x86_64-unix/wine"
        XCTAssertTrue(WineWindowPolicy.hasRaisedGameWindowShape(27, "Genshin Impact"))
        XCTAssertTrue(WineWindowPolicy.isWineExecutablePath(path))
        XCTAssertTrue(WineWindowPolicy.isWineProcess(nil, path, "wine"))
        XCTAssertTrue(WineWindowPolicy.isAcceptableLevel(27))
    }

    /// Geometry Dash under CrossOver: same shape, different path convention and process name.
    func testGeometryDashUnderCrossOverIsRecognized() {
        let path = "/private/var/folders/_8/g635xwbj46141qbl7vlhc0ww0000gn/T//winetemp-6708606-33568-1784110844-0/GeometryDash.exe"
        XCTAssertTrue(WineWindowPolicy.hasRaisedGameWindowShape(21, "Geometry Dash"))
        XCTAssertTrue(WineWindowPolicy.isWineExecutablePath(path))
        XCTAssertTrue(WineWindowPolicy.isWineProcess(nil, path, "GeometryDash.exe"))
        XCTAssertTrue(WineWindowPolicy.isAcceptableLevel(21))
    }

    // MARK: - G. Blank-capture skip (thumbnails)

    private static let genshinPath = "/Users/halp/Library/Application Support/Yaagl OS/wine/lib/wine/x86_64-unix/wine"
    private static let geometryDashPath = "/private/var/folders/_8/g635xwbj46141qbl7vlhc0ww0000gn/T//winetemp-6708606-33568-1784110844-0/GeometryDash.exe"

    /// The one state with live content: the game focused, its app in front, switcher down. This is exactly
    /// when `captureFocusedInBackground` runs, and it captures perfectly there (3232 distinct colours).
    func testFocusedFrontmostWineWindowIsCaptured() {
        XCTAssertFalse(WineWindowPolicy.yieldsBlankCapture(isSwitcherActive: false, isFrontmostApp: true, isFocusedWindow: true))
    }

    /// Summoning the switcher is what makes Wine minimize the game, so a capture taken then is always blank —
    /// this is the one that used to overwrite the good thumbnail on every single show.
    func testCaptureWhileSwitcherIsUpYieldsBlank() {
        XCTAssertTrue(WineWindowPolicy.yieldsBlankCapture(isSwitcherActive: true, isFrontmostApp: true, isFocusedWindow: true))
    }

    /// A background capture pass while the user is in another app: the game is still its app's focused
    /// window, but the app is not in front, so there is nothing to capture.
    func testBackgroundCaptureOfNonFrontmostWineAppYieldsBlank() {
        XCTAssertTrue(WineWindowPolicy.yieldsBlankCapture(isSwitcherActive: false, isFrontmostApp: false, isFocusedWindow: true))
    }

    /// Another window of the same Wine app has focus — the game itself is not on screen.
    func testUnfocusedWineWindowYieldsBlank() {
        XCTAssertTrue(WineWindowPolicy.yieldsBlankCapture(isSwitcherActive: false, isFrontmostApp: true, isFocusedWindow: false))
    }

    /// The identity half of the same decision, on the two real games and on the native launcher beside them.
    func testBlankCaptureIdentityMatchesTheRealProcesses() {
        XCTAssertTrue(WineWindowPolicy.isWineProcess(nil, Self.genshinPath, "wine"))
        XCTAssertTrue(WineWindowPolicy.isWineProcess(nil, Self.geometryDashPath, "GeometryDash.exe"))
        XCTAssertFalse(WineWindowPolicy.isWineProcess("com.apple.TextEdit",
            "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit", "TextEdit"))
    }

    /// The raised, titled windows a real desktop has alongside the games — all rejected on identity.
    func testRealDesktopRaisedWindowsAreNotWine() {
        let raised = [("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", "Battery"),
                      ("/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter", "Daily Activity"),
                      ("/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight", "Spotlight"),
                      ("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", "Dock")]
        for (path, title) in raised {
            XCTAssertTrue(WineWindowPolicy.hasRaisedGameWindowShape(25, title), title)
            XCTAssertFalse(WineWindowPolicy.isWineExecutablePath(path), path)
        }
    }
}
