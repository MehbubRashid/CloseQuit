//
//  Policy.swift
//  CloseQuit
//
//  The decision rules, kept free of Accessibility and window-server calls so they can be
//  unit-tested. Every rule leans the same way: when something is unclear, the answer is
//  "leave the app alone".
//

import CoreGraphics
import Foundation

// MARK: - Apps that are never quit

enum Denylist {
    /// Apps CloseQuit refuses to manage whatever the list says. Quitting Finder would take
    /// the desktop with it; the others are parts of macOS itself.
    static let bundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.WindowManager",
    ]

    static func contains(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID) || bundleID == Bundle.main.bundleIdentifier
    }
}

// MARK: - ⌘W

enum ShortcutMatcher {
    /// Virtual key code of the W key on ANSI keyboards.
    static let wKeyCode: Int64 = 13

    /// Key code 13 with Command as the only modifier: ⇧⌘W, ⌥⌘W and ⌃⌘W are different commands.
    static func isCommandWChord(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == wKeyCode, flags.contains(.maskCommand) else { return false }
        return flags.isDisjoint(with: [.maskShift, .maskAlternate, .maskControl, .maskSecondaryFn])
    }

    /// The chord above, and the key must actually type "w". On other layouts key code 13 is a
    /// different command (⌘Z Undo on AZERTY, ⌘, Settings on Dvorak), which must never count as a close.
    static func isPlainCommandW(keyCode: Int64, flags: CGEventFlags, characters: String?) -> Bool {
        isCommandWChord(keyCode: keyCode, flags: flags) && characters?.lowercased() == "w"
    }
}

// MARK: - Close-button clicks

enum ClickPolicy {
    /// ⌃-click is a secondary click; it never presses a close button.
    static func ignoresMouseDown(flags: CGEventFlags) -> Bool {
        flags.contains(.maskControl)
    }

    /// A close button only fires when the mouse is released inside it; dragging off before
    /// letting go cancels. The frame is captured at mouse-down because by the time we could
    /// hit-test again after mouse-up, the app may already have closed the window.
    static func releaseConfirmsClose(buttonFrame: CGRect, releaseLocation point: CGPoint) -> Bool {
        guard !buttonFrame.isEmpty else { return false }
        // Edges included: a release on the button's last point still presses it.
        return point.x >= buttonFrame.minX && point.x <= buttonFrame.maxX
            && point.y >= buttonFrame.minY && point.y <= buttonFrame.maxY
    }
}

// MARK: - Window classification (Accessibility)

enum WindowKind: String {
    /// AXStandardWindow, including minimized and full-screen windows. A real window.
    case standard
    /// A sheet or a dialog ("Save changes?"). Blocks quitting and starts the 30 s watch.
    case dialog
    /// Looks like a real window but has an unrecognised role or subrole. Treated as real.
    case ambiguous
    /// Floating panels, palettes, popovers and tiny helper windows. Ignored.
    case ignorable

    var isRealWindow: Bool { self == .standard || self == .ambiguous }
}

struct WindowTraits: Equatable {
    var role: String?
    var subrole: String?
    var isMinimized = false
    var size: CGSize?
}

enum WindowClassifier {
    /// Anything smaller than this that we can't otherwise identify is treated as a helper window.
    static let minimumRealSize = CGSize(width: 100, height: 60)

    static func classify(_ traits: WindowTraits) -> WindowKind {
        switch traits.role {
        case "AXSheet"?:
            return .dialog
        case "AXPopover"?, "AXDrawer"?:
            return .ignorable
        case "AXWindow"?:
            switch traits.subrole {
            case "AXStandardWindow"?:
                return .standard
            case "AXDialog"?, "AXSystemDialog"?:
                return .dialog
            case "AXFloatingWindow"?, "AXSystemFloatingWindow"?:
                return .ignorable
            default:
                return looksLikeRealWindow(traits) ? .ambiguous : .ignorable
            }
        default:
            return looksLikeRealWindow(traits) ? .ambiguous : .ignorable
        }
    }

    /// Whether `classify` needs the minimized state and size (only for unrecognised windows).
    static func needsShape(_ traits: WindowTraits) -> Bool {
        switch (traits.role, traits.subrole) {
        case ("AXSheet"?, _), ("AXPopover"?, _), ("AXDrawer"?, _):
            return false
        case ("AXWindow"?, "AXStandardWindow"?), ("AXWindow"?, "AXDialog"?), ("AXWindow"?, "AXSystemDialog"?),
             ("AXWindow"?, "AXFloatingWindow"?), ("AXWindow"?, "AXSystemFloatingWindow"?):
            return false
        default:
            return true
        }
    }

    static func looksLikeRealWindow(_ traits: WindowTraits) -> Bool {
        if traits.isMinimized { return true }
        guard let size = traits.size else { return true }  // can't tell: assume it's real
        return size.width >= minimumRealSize.width && size.height >= minimumRealSize.height
    }
}

// MARK: - Window-server facts

/// One entry from the window server's list (CGWindowListCopyWindowInfo).
struct ServerWindow: Equatable {
    var id: UInt32
    var layer: Int
    var alpha: Double
    var bounds: CGRect
    var isOnscreen: Bool
    /// The Spaces this window is assigned to; `nil` means not looked up or unknown.
    var spaces: [UInt64]?
    var ownerPID: Int32 = 0
}

enum ServerWindowPolicy {
    /// kCGMainMenuWindowLevel. App windows below it can be ordinary windows the user sees.
    static let menuBarLayer = 24
    static let minimumCandidateSize = CGSize(width: 20, height: 20)

    /// A normal-level, visible, window-sized window: what an on-screen document window looks like.
    static func isUserSized(_ window: ServerWindow) -> Bool {
        window.layer == 0 && window.alpha > 0.01
            && window.bounds.width >= WindowClassifier.minimumRealSize.width
            && window.bounds.height >= WindowClassifier.minimumRealSize.height
    }

    /// Anything that could be a window the user keeps on another Space: any level below the
    /// menu bar (so "Float on Top" windows count), any opacity. Only tiny helpers are skipped.
    static func isSpaceCandidate(_ window: ServerWindow) -> Bool {
        (0..<menuBarLayer).contains(window.layer)
            && window.bounds.width >= minimumCandidateSize.width
            && window.bounds.height >= minimumCandidateSize.height
    }

    /// Off screen, but parked on a Space nobody is looking at right now: another desktop,
    /// a full-screen Space, or minimized from another desktop. AXWindows does not list
    /// these, so they would otherwise look like "no windows left".
    /// Hidden windows on the current Space (hide-on-close apps) and windows that were
    /// never shown (no Space at all) don't count.
    static func isOnHiddenSpace(_ window: ServerWindow, visibleSpaces: Set<UInt64>?) -> Bool {
        guard !window.isOnscreen else { return false }
        guard let spaces = window.spaces else { return true }               // unknown: assume the worst
        guard let visible = visibleSpaces else { return !spaces.isEmpty }   // unknown: any Space counts
        return spaces.contains { !visible.contains($0) }
    }

    /// Off screen and assigned only to Spaces that are visible: how a hidden (ordered-out)
    /// window looks, but also how a window set aside by Stage Manager might look.
    static func isParkedOnVisibleSpace(_ window: ServerWindow, visibleSpaces: Set<UInt64>?) -> Bool {
        guard !window.isOnscreen, let spaces = window.spaces, !spaces.isEmpty, let visible = visibleSpaces else {
            return false
        }
        return spaces.allSatisfy(visible.contains)
    }

    /// On screen, but not one of the windows Accessibility reported.
    static func isUnaccountedOnscreen(_ window: ServerWindow, accessibilityIDs: Set<UInt32>?, displays: [CGRect]) -> Bool {
        guard window.isOnscreen else { return false }
        guard displays.isEmpty || displays.contains(where: { $0.intersects(window.bounds) }) else { return false }
        guard let ids = accessibilityIDs else { return true }               // can't match them up: assume the worst
        return !ids.contains(window.id)
    }

    /// The Spaces lookup is undocumented, so check it still answers sensibly before trusting
    /// it: something on screen (at least the desktop picture) always sits on a visible Space.
    static func spacesLookupLooksHealthy(onscreenWindowSpaces: [[UInt64]], visibleSpaces: Set<UInt64>?) -> Bool {
        guard let visible = visibleSpaces, !visible.isEmpty else { return false }
        return onscreenWindowSpaces.contains { $0.contains(where: visible.contains) }
    }
}

// MARK: - Verdict

struct WindowCensus: Equatable {
    var standard = 0
    var ambiguous = 0
    var dialogs = 0
    var ignored = 0
    var onHiddenSpaces = 0
    var unaccountedOnscreen = 0
    /// Off-screen windows on a visible Space while Stage Manager is on (possibly set aside, not closed).
    var setAside = 0
    var appHidden = false

    var summary: String {
        var parts = ["\(standard) standard"]
        if ambiguous > 0 { parts.append("\(ambiguous) unrecognised") }
        if dialogs > 0 { parts.append("\(dialogs) sheet/dialog") }
        if ignored > 0 { parts.append("\(ignored) panel") }
        if onHiddenSpaces > 0 { parts.append("\(onHiddenSpaces) on other Spaces") }
        if unaccountedOnscreen > 0 { parts.append("\(unaccountedOnscreen) unreported on screen") }
        if setAside > 0 { parts.append("\(setAside) set aside by Stage Manager") }
        if appHidden { parts.append("app hidden") }
        return parts.joined(separator: ", ")
    }
}

enum Verdict: Equatable {
    /// Nothing left that could be a window the user still wants. Quit only if this holds twice.
    case noWindowsLeft
    /// Real windows are still open; `dialog` if a sheet or dialog is showing too.
    case windowsRemain(count: Int, dialog: Bool)
    /// No real windows, but a sheet or dialog is up.
    case dialogOnly
    /// Something doesn't add up. Never quit on this.
    case unsure(String)
}

enum Decider {
    static func verdict(_ census: WindowCensus) -> Verdict {
        let real = census.standard + census.ambiguous
        if real > 0 { return .windowsRemain(count: real, dialog: census.dialogs > 0) }
        if census.dialogs > 0 { return .dialogOnly }
        if census.appHidden { return .unsure("it is hidden") }
        if census.onHiddenSpaces > 0 { return .unsure("it still has a window on another Space") }
        if census.unaccountedOnscreen > 0 { return .unsure("a window that Accessibility doesn't report is on screen") }
        if census.setAside > 0 { return .unsure("Stage Manager is on and it may have a window set aside") }
        return .noWindowsLeft
    }

    static func stillOpenPhrase(_ count: Int) -> String {
        count == 1 ? "1 window is still open" : "\(count) windows are still open"
    }
}

// MARK: - What to do after each look

enum NextStep: Equatable {
    /// Looks closed: look again shortly (Chrome briefly destroys and recreates windows).
    case recheck
    case quit
    /// Keep an eye on the app: `dialog` for a save dialog (30 s), otherwise a short grace period.
    case watch(dialog: Bool)
    /// Leave the app alone.
    case stop(String)
}

enum DecisionPolicy {
    static let recheckDelay: TimeInterval = 0.3
    static let dialogWatchDuration: TimeInterval = 30
    /// The closed window is still there at the first look (a slow app, a full-screen exit animation).
    static let closingGraceDuration: TimeInterval = 3
    /// A dialog went away but the window stayed: if nothing closes within this, assume "Cancel".
    static let dialogCancelGrace: TimeInterval = 5
    /// Allowance for timer latency when the deadline check runs.
    static let deadlineTolerance: TimeInterval = 0.5
    static let spacesChangedPhrase = "the visible Spaces changed while checking"

    /// First look, `checkDelay` after the close action.
    static func afterFirstLook(_ verdict: Verdict, closedWindowStillOpen: Bool?) -> NextStep {
        switch verdict {
        case .noWindowsLeft:
            return .recheck
        case .dialogOnly:
            return .watch(dialog: true)
        case .windowsRemain(let count, let dialog):
            // The window that was closed is gone but others are open: it wasn't the last one,
            // whatever else is showing.
            if closedWindowStillOpen == false { return .stop(Decider.stillOpenPhrase(count)) }
            if dialog { return .watch(dialog: true) }
            return closedWindowStillOpen == true ? .watch(dialog: false) : .stop(Decider.stillOpenPhrase(count))
        case .unsure(let reason):
            return .stop(reason)
        }
    }

    /// Second look, `recheckDelay` after a look that found no windows.
    static func afterRecheck(_ verdict: Verdict, spacesUnchanged: Bool) -> NextStep {
        if case .unsure(let reason) = verdict { return .stop(reason) }
        guard spacesUnchanged else { return .stop(spacesChangedPhrase) }
        switch verdict {
        case .noWindowsLeft:
            return .quit
        case .dialogOnly:
            return .watch(dialog: true)
        case .windowsRemain:
            return .stop("a window came back")
        case .unsure(let reason):
            return .stop(reason)
        }
    }
}

// MARK: - Watching an app that hasn't finished closing

struct WatchState: Equatable {
    /// When the user closed the window. The 30 s window is measured from here.
    let startedAt: TimeInterval
    var deadline: TimeInterval
    var dialogSeen: Bool
    var dialogGoneSince: TimeInterval?
}

enum WatchStep: Equatable {
    case recheck
    case quit
    case keepWatching(lookAgainAt: TimeInterval?)
    case stop(String)
}

enum WatchPolicy {
    static func start(actionTime: TimeInterval, dialog: Bool) -> WatchState {
        let duration = dialog ? DecisionPolicy.dialogWatchDuration : DecisionPolicy.closingGraceDuration
        return WatchState(startedAt: actionTime, deadline: actionTime + duration, dialogSeen: dialog, dialogGoneSince: nil)
    }

    /// Something changed (a window or sheet went away or appeared), or a timer fired.
    static func evaluate(_ verdict: Verdict, closedWindowStillOpen: Bool?, state: inout WatchState, now: TimeInterval) -> WatchStep {
        let expired = now >= state.deadline
        switch verdict {
        case .unsure(let reason):
            return .stop(reason)
        case .noWindowsLeft:
            if now > state.deadline + DecisionPolicy.deadlineTolerance { return .stop(timeoutPhrase(state)) }
            return .recheck
        case .windowsRemain(let count, _) where closedWindowStillOpen == false:
            // The window the user closed is gone, but others are open: it wasn't the last one.
            return .stop(Decider.stillOpenPhrase(count))
        case _ where expired:
            return .stop(timeoutPhrase(state))
        case .dialogOnly, .windowsRemain(_, dialog: true):
            state.dialogSeen = true
            state.dialogGoneSince = nil
            state.deadline = max(state.deadline, state.startedAt + DecisionPolicy.dialogWatchDuration)
            return .keepWatching(lookAgainAt: nil)
        case .windowsRemain(_, dialog: false):
            guard state.dialogSeen else { return .keepWatching(lookAgainAt: nil) }
            let since = state.dialogGoneSince ?? now
            state.dialogGoneSince = since
            if now - since >= DecisionPolicy.dialogCancelGrace {
                return .stop("the dialog was dismissed and the window stayed open")
            }
            return .keepWatching(lookAgainAt: since + DecisionPolicy.dialogCancelGrace)
        }
    }

    /// The confirmation look, `recheckDelay` after a look that found no windows.
    static func afterRecheck(_ verdict: Verdict, closedWindowStillOpen: Bool?, spacesUnchanged: Bool,
                             state: inout WatchState, now: TimeInterval) -> WatchStep {
        if case .noWindowsLeft = verdict {
            guard spacesUnchanged else { return .stop(DecisionPolicy.spacesChangedPhrase) }
            let latest = state.deadline + DecisionPolicy.deadlineTolerance + DecisionPolicy.recheckDelay
            guard now <= latest else { return .stop(timeoutPhrase(state)) }
            return .quit
        }
        return evaluate(verdict, closedWindowStillOpen: closedWindowStillOpen, state: &state, now: now)
    }

    private static func timeoutPhrase(_ state: WatchState) -> String {
        state.dialogSeen
            ? "its window was still open after \(Int(DecisionPolicy.dialogWatchDuration)) s"
            : "its window didn't close"
    }
}
