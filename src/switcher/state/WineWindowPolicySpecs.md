# WineWindowPolicy — Specs

## Summary

Windows apps run on macOS through a **Wine** wrapper: CrossOver, Yaagl, Whisky, Wineskin, Porting Kit, or
plain Wine. Their windows are not AppKit windows in any normal sense, and two independent AltTab gates drop
them, so a running game shows in the switcher as a windowless app icon (or not at all).

`WineWindowPolicy` is the pure kernel that recognises them. It answers two questions — *is this level one a
Wine window may sit at?* and *is this process running under Wine?* — and holds the measured constants both
answers depend on. `WindowDiscriminator` applies it at both gates; `WineWindowPolicyTests` pins it.

## What Wine windows actually look like

Measured live on macOS 26.5 with CrossOver 26.3 (Steam → "Geometry Dash") and Yaagl (Genshin Impact),
reading the `SLSWindowQueryWindows` snapshot and the AX tree side by side:

| | game window | Wine's helper windows |
|---|---|---|
| CGS level | **21 or 27**, never 0 | 0 |
| title | the game's ("Genshin Impact") | empty |
| size | screen-sized (1512x982) | 1512x33 (menu-bar proxy) / 500x500 (desktop stand-in) |
| `spaceTypeMask` | `0x1` (a real user Space) | `0x0` |
| AX role / subrole | `AXWindow` / **`AXUnknown`** | no AX element at all |
| bundle id | `nil` | `nil` |

The **level is the headline fact**: 27 while the game holds focus, 21 once Wine minimizes it on focus loss
(which Wine does for a fullscreen game). Wine's macdrv raises the window over the Dock (20) and the menu bar
(24/25) so the game can cover them. It is never 0 in either state, so a level-0 gate can never see it.

## The two gates it feeds

1. **The coarse WindowServer gate** (`WsWindowState.isApplicationWindowLevel`, level == 0). This runs on the
   raw snapshot, *before* an AX element is acquired, so a Wine game window was rejected before AX — which
   holds a perfectly good `AXWindow` element for it — was ever consulted. This is the gate that made the
   window invisible to AltTab in every state.
2. **The fine AX gate** (`WindowDiscriminator.isActualWindow`). Wine's subrole is `AXUnknown`, so the
   standard-subrole path can't accept it either; it needs the explicit `wineWindow` rule.

## Behavior & edge cases

- **`maxLevel` is `statusWindow + 2` (27)** — the measured ceiling. It is a ceiling, not a whitelist of
  {21, 27}, because the exact value is Wine's business and has moved before. It deliberately stops well
  below `popUpMenu` (101), where Wine puts its own menus and tooltips: those must stay out.
- **`hasRaisedGameWindowShape` is an optimization gate, not the verdict.** It exists so the coarse gate pays
  for a `KERN_PROCARGS` read only on windows that could plausibly be one. On a full desktop it narrows ~195
  windows to ~22 (Control Center items, menu-bar extras, Notification Center, Spotlight, the Dock, and the
  two game windows); the executable-path test then rejects all but the Wine ones. Measured cost of the read:
  **5.5µs**, on the off-main `cgsCall` lane — so ~120µs per discovery pass, and no cache is warranted.
- **Untitled windows are excluded by shape.** That is what keeps Wine's own helper windows out of the
  process lookup, and it is safe because a game window always carries the game's title.
- **Identity is matched on the executable path, never the process name.** Under CrossOver the process is
  named for the Windows binary (`GeometryDash.exe`) and lives in a per-bottle temp copy
  (`…/T/winetemp-<id>/GeometryDash.exe`); under Yaagl it is named for the loader (`wine`) and lives in a
  Wine tree (`…/Yaagl OS/wine/lib/wine/x86_64-unix/wine`). No single name covers both. The pattern therefore
  matches `/winetemp-`, any `/wine/` directory component, or a loader basename (`wine`, `wine64`,
  `wineloader`, `wine-preloader`, `wine64-preloader`, `wineserver`).
- **`isWineProcess` requires a nil bundle id.** Every Wine-hosted process has one; requiring it keeps the
  rule from ever firing on a native app that merely lives under a path containing `wine`. It also correctly
  excludes the **Yaagl launcher itself** (`com.3shain.yaagl.os`), which is a native app whose window is an
  ordinary `AXStandardWindow` and has always worked — only the *game* it launches needed this.
- **The name fallback (`loaderNames`) is for the pre-2023 CrossOver shape**, whose process name was the
  loader's (`wine64-preloader`) and which the original rule keyed on. It only applies when the path test
  misses, and still requires a nil bundle id.
- **Negative levels are excluded** (`isAcceptableLevel` floors at 0): the wallpaper and desktop icons sit far
  below 0 and are not windows.

## Thumbnails: why an ordered-out Wine window must not be captured

A Wine game renders through a GPU surface that goes away when the WindowServer orders the window out. Measured
with ScreenCaptureKit on macOS 26.5, capturing the same window in both states:

| window | on screen | ordered out |
|---|---|---|
| Genshin Impact (Yaagl) | 3232 distinct colours — the real frame | 1 colour, opaque `#1E1E1E` |
| Geometry Dash (CrossOver) | — | 1 colour, fully transparent |
| **TextEdit (native control)** | 153 colours | **141 colours — still real** |

The native control is the important row: macOS keeps a minimized window's backing store, so this is not "you
cannot screenshot a minimized window". It is specific to Wine, and it is why the skip must be Wine-only —
applying it to every off-screen window would replace working thumbnails with app icons.

It bites much harder than the rarity suggests, because **Wine minimizes a fullscreen game the moment it loses
focus** — which is exactly what summoning the switcher does. So the show's own capture always ran against an
ordered-out window, accepted the blank frame, and overwrote the good thumbnail; the tile was blank every time.
`WindowThumbnails.acceptCapture` could not catch it: it only rejects frames drawn *smaller* than the window,
and these come back at exactly the right size.

The good thumbnail comes from `captureFocusedInBackground`, which fires on `.applyFocus` while the game is
still on screen (verified live: a capture of Genshin landed 0.5s after its focus event). Skipping the later
blank captures is what lets that one survive.

**The condition is "the game is focused and in front", not any single window-state bit.** Two weaker tests
were tried against the live app and both let blank frames through:

- **`isMinimized`** is never set for these windows. An order-out is ambiguous (minimize / hide / other-Space /
  closing), so the reducer only records the wid in `carried.offScreen`. The live log shows
  `windowOrderedOut #2276` and `unminimized #2276`, and never `minimized` — so a guard keyed on it is false
  for exactly the window it must catch.
- **The WindowServer's ordered-in bit** (`WsWindowState.isVisible`), read at capture time, is closer but still
  wrong: restoring the game flickers it ordered-in before Wine has drawn — measured as an order-in/order-out
  pair 300ms apart — and a capture landing in that gap is blank while every state bit says the window is up.

What holds is the positive statement: Wine has content to give only while the game is the **focused window of
the frontmost app**, with the switcher down. `captureFocusedInBackground` is the only capture path that runs
in that state, so admitting exactly it keeps the good thumbnail and drops every clobbering pass — the
show-time refresh (switcher up) and the background sweep (app not in front) alike.

Skipping (rather than capturing and then judging the pixels) is deliberate: it costs nothing, it spares a
pointless ScreenCaptureKit round-trip per show, and a pixel-based "is this frame blank" test was measured to
be both expensive and unreliable — rescaling a flat frame to a small sampling grid introduces edge artifacts
that read as non-flat (the Genshin frame, uniform `#1E1E1E` at full size, sampled as two distinct values).

## What this does NOT fix

- **A Wine window with no AX element is still dropped**, by `acquireElementOrReject`. Measured: an
  *ordered-out* Wine window (Steam closed to tray — CGS still lists wid 412 "Steam" at level 0) exposes no
  AX element at all, via neither `kAXWindows` nor the remote-token brute force, so there is nothing to
  acquire. Wine only vends AX for windows it has ordered in. That is a separate limitation from the level
  gate, and it is why fixing the level does not resurrect a tray-closed Steam window.
- **The app's displayed name is the loader's** ("wine") for wrappers that run the loader directly, because
  that is what `NSRunningApplication.localizedName` reports. The window's own title is correct
  ("Genshin Impact"), which is what the switcher shows on the tile.
