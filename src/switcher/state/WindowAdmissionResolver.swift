import Cocoa

/// WindowServer-owned facts about one painted surface. A surface is not necessarily something the switcher
/// should offer: sheets, children, panels and menus are surfaces too.
struct PhysicalSurface: Equatable {
    let wid: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let level: CGWindowLevel
    let parentWid: CGWindowID
    let isVisible: Bool
    let isMinimized: Bool
    let isFullscreen: Bool
    let alpha: Float
    /// Wine raises a screen-covering game window over the Dock and the menu bar, on an ORDINARY user Space —
    /// so it is neither level 0 nor fullscreen-tagged, and it carries subrole `AXUnknown`, which means no
    /// other field here vouches for it. Resolved from the WindowServer row because it is a fact about the
    /// owning process, not about AX. See `WineWindowPolicySpecs.md`.
    let isWineGameWindow: Bool

    init(wid: CGWindowID, pid: pid_t, bounds: CGRect, level: CGWindowLevel, parentWid: CGWindowID = 0,
         isVisible: Bool = true, isMinimized: Bool = false, isFullscreen: Bool = false, alpha: Float = 1,
         isWineGameWindow: Bool = false) {
        self.wid = wid
        self.pid = pid
        self.bounds = bounds
        self.level = level
        self.parentWid = parentWid
        self.isVisible = isVisible
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.alpha = alpha
        self.isWineGameWindow = isWineGameWindow
    }

    init(_ raw: WsRawWindow) {
        self.init(wid: raw.wid, pid: raw.pid, bounds: raw.bounds,
            level: CGWindowLevel(raw.level), parentWid: raw.parentWid,
            isVisible: WsWindowState.isVisible(raw), isMinimized: WsWindowState.isMinimized(raw),
            isFullscreen: WsWindowState.isFullscreen(raw), alpha: raw.alpha,
            isWineGameWindow: PhysicalSurface.resolveWineGameWindow(raw))
    }

    /// Shape first, so the `KERN_PROCARGS` read (5.5µs measured) is paid only by the raised windows a full
    /// desktop has rather than by all of them. Wine's menus sit at 101+, above the ceiling, so they are
    /// dropped before the process lookup.
    ///
    /// **The title deliberately does NOT gate this.** `SLSWindowIteratorCopyTitle` only returns a string when
    /// the query asked for ONE wid: measured on macOS 26.5, querying wid 18025 alone gives "Geometry Dash"
    /// 100/100 times, while the same wid inside a batch of 2 or 10 gives "" 100/100 times. AltTab batches
    /// (`refreshWindowsViaWindowServer`, `refreshWindowServerState`), so `raw.title` is empty on exactly the
    /// passes that re-run admission for an already-tracked window. Gating on it made the Wine vouch flicker
    /// off mid-session and the game was then rejected as an `auxiliarySurface` and replaced by a windowless
    /// icon — with the title read a moment earlier, by a single-wid query, having been correct.
    ///
    /// Dropping the title costs nothing real: process identity is the actual verdict, and Wine's helper
    /// windows (the 1512x33 menu-bar proxy, the 500x500 desktop stand-in) sit at level 0, so the raised-level
    /// test already excludes them without help from the title.
    ///
    /// The bundle id is read from `NSRunningApplication`, whose header documents it as thread safe (see
    /// `src/main-thread-ipc.md`), because a CrossOver bottle-app launcher is identified by bundle id and
    /// `KERN_PROCARGS` carries only the path. It is read only for a window that already passed the level
    /// test — a handful per desktop — so the LaunchServices lookup is not on any per-window hot path.
    private static func resolveWineGameWindow(_ raw: WsRawWindow) -> Bool {
        guard WineWindowPolicy.isRaisedGameWindowLevel(CGWindowLevel(raw.level)) else { return false }
        let executablePath = Sysctl.run([CTL_KERN, KERN_PROCARGS, raw.pid])
        if WineWindowPolicy.isWineExecutablePath(executablePath) { return true }
        let runningApplication = NSRunningApplication(processIdentifier: raw.pid)
        return WineWindowPolicy.isCrossOverBottleApp(runningApplication?.bundleIdentifier, executablePath)
    }

    var isSubstantial: Bool {
        bounds.width >= WindowAdmissionResolver.minimumWidth &&
            bounds.height >= WindowAdmissionResolver.minimumHeight
    }
}

/// Accessibility-owned meaning for a physical surface. Nil fields are evidence too: broken/custom toolkits
/// often expose a real AXWindow root while omitting the conventional subrole.
struct SemanticSurface: Equatable {
    let title: String?
    let subrole: String?
    let role: String?
    let isMain: Bool?

    var hasTitle: Bool { !(title ?? "").isEmpty }
    var isWindowRole: Bool { role == kAXWindowRole }
}

enum WindowAdmissionEvidence: Equatable {
    case discovery
    case attention
}

enum WindowAdmissionReason: String, Equatable {
    case invalidWindowId
    case attachedSurface
    case exactAttention
    case awaitingAccessibility
    case conventionalWindow
    case mainWindow
    case customWindowRoot
    case auxiliarySurface
    case untitledDialog
    case undersizedCustomSurface
    case nonWindowRole
    case unsupportedSemantics
}

/// The user-facing result is deliberately richer than a Boolean. A painted surface may itself be a switch
/// destination, represent another destination, need more evidence, or be known not to be one.
enum SwitchDestinationDecision: Equatable {
    case destination(WindowAdmissionReason)
    case represent(parentWid: CGWindowID, WindowAdmissionReason)
    case latent(WindowAdmissionReason)
    case reject(WindowAdmissionReason)

    var reason: WindowAdmissionReason {
        switch self {
        case let .destination(reason), let .represent(_, reason), let .latent(reason), let .reject(reason):
            return reason
        }
    }

    var isDestination: Bool {
        if case .destination = self { return true }
        return false
    }
}

/// Resolves physical, semantic and behavioral evidence into a switch destination. Rules are ordered by
/// authority rather than scored: exact relationships beat behavioral evidence, which beats conventions,
/// which beat coarse size/level priors.
enum WindowAdmissionResolver {
    static let minimumWidth: CGFloat = 100
    static let minimumHeight: CGFloat = 50
    static let normalLevel: CGWindowLevel = 0

    /// Whether ordinary discovery should pay the AX acquisition cost. Level zero is a cheap positive hint,
    /// never a rejection: a substantial non-zero-level surface is inspected too, and exact attention bypasses
    /// this optimization entirely.
    static func shouldAcquireSemantics(_ physical: PhysicalSurface) -> Bool {
        physical.wid != 0 && physical.parentWid == 0 &&
            (physical.level == normalLevel || physical.isSubstantial)
    }

    static func resolve(_ physical: PhysicalSurface, _ semantic: SemanticSurface?,
                        evidence: WindowAdmissionEvidence = .discovery) -> SwitchDestinationDecision {
        guard physical.wid != 0 else { return .reject(.invalidWindowId) }
        guard physical.parentWid == 0 else { return .represent(parentWid: physical.parentWid, .attachedSurface) }
        if let semantic, isAuxiliary(semantic.subrole) { return .reject(.auxiliarySurface) }
        if evidence == .attention { return attentionDecision(physical, semantic) }
        guard let semantic else { return .latent(.awaitingAccessibility) }
        guard admissiblePlacement(physical, semantic) else { return .reject(.auxiliarySurface) }
        if semantic.isWindowRole && semantic.isMain == true { return .destination(.mainWindow) }
        if semantic.subrole == kAXStandardWindowSubrole { return .destination(.conventionalWindow) }
        if semantic.subrole == kAXDialogSubrole {
            return semantic.hasTitle ? .destination(.conventionalWindow) : .latent(.untitledDialog)
        }
        if semantic.isWindowRole && semantic.hasTitle && physical.isSubstantial {
            return .destination(.customWindowRoot)
        }
        guard semantic.isWindowRole else { return .reject(.nonWindowRole) }
        guard physical.isSubstantial else { return .latent(.undersizedCustomSurface) }
        return .latent(.unsupportedSemantics)
    }

    private static func isAuxiliary(_ subrole: String?) -> Bool {
        subrole == kAXFloatingWindowSubrole || subrole == "AXSystemDialog"
    }

    /// **Above the ordinary window level, a subrole is not authority; `kAXMain` is.** A surface an app places
    /// over its own document windows is a HUD, a panel, an overlay or a presentation, and only the last of
    /// those is somewhere to switch to. AppKit reserves `kAXMain` for the one window an app would restore the
    /// user to, and it survives the app going to the background (measured across Chrome, TextEdit and
    /// ChatGPT, all reporting `AXMain` true for a background window), so it is a fact about the surface
    /// rather than about who is in front.
    ///
    /// The subrole cannot do this job. ChatGPT's dictation strip is a 720x84 bar at level 3 that Chromium
    /// describes as a titled `AXDialog`, and its floating sidebar as `AXStandardWindow`; the same two
    /// subroles name the ordinary windows of every AppKit app. Gating them by placement is what separates
    /// them, and it is why this is one rule over every subrole instead of a list of the ones caught so far
    /// (#5565).
    ///
    /// Covering the screen is the other positive vouch: a fullscreen surface is where the user already is,
    /// whatever level the WindowServer parks it at.
    ///
    /// A Wine game window is the third, and it needs its own vouch because it satisfies none of the others:
    /// Wine raises it over the Dock / menu-bar band on an ordinary Space, and hands it subrole `AXUnknown`
    /// with `kAXMain` unset, so level, the fullscreen bit and AX all decline to speak for it.
    private static func admissiblePlacement(_ physical: PhysicalSurface, _ semantic: SemanticSurface?) -> Bool {
        physical.level == normalLevel || physical.isFullscreen || physical.isWineGameWindow ||
            semantic?.isMain == true
    }

    /// **Exact attention fills a silence; it does not overrule an answer.** Both channels that reach here read
    /// `kAXFocusedWindow`, the app's own focus notification and the activation read, and that attribute names
    /// floating panels and borderless HUDs where `kAXMain` names neither, measured across ~100 installed apps
    /// in #5983. So attention is evidence about where focus went, never about what the surface IS.
    ///
    /// Which is why `admissiblePlacement` binds here too, and it is the whole reason the gate holds. An app
    /// that key-focuses its own HUD reaches attention exactly as a real window does — ChatGPT's dictation
    /// strip takes focus the moment it appears — so a placement rule that discovery applied and attention did
    /// not would only delay the surface by one focus event.
    ///
    /// What attention does buy is the benefit of the doubt on meaning. A role that is not a window still
    /// refuses it: that is the flattest refusal accessibility can make, and a surface the app calls a group is
    /// not a switch destination however the focus got there. A role it FAILED to read is not that refusal — a
    /// nil role is the absence of an answer, and reading absence as a verdict is the mistake
    /// `WindowElementAcquisition` exists to prevent.
    private static func attentionDecision(_ physical: PhysicalSurface,
                                          _ semantic: SemanticSurface?) -> SwitchDestinationDecision {
        guard admissiblePlacement(physical, semantic) else { return .reject(.auxiliarySurface) }
        guard let semantic else { return .destination(.exactAttention) }
        guard semantic.role == nil || semantic.isWindowRole else { return .reject(.nonWindowRole) }
        return .destination(.exactAttention)
    }
}
