//
//  WindowInspector.swift
//  CloseQuit
//
//  Answers "does this app still have a window?" by asking Accessibility (what kind of
//  windows are there?) and the window server (is anything on another Space, or on screen
//  but missing from Accessibility?). Engine.queue only.
//

import AppKit
import ApplicationServices

struct Inspection {
    var verdict: Verdict
    var census = WindowCensus()
    /// For actions where we know which window was closed: is it still in the window list?
    var closedWindowStillOpen: Bool?
    /// Windows and sheets to observe with kAXUIElementDestroyedNotification while watching.
    var watchTargets: [AXUIElement] = []
    /// The Spaces on screen during this look (nil if unknown). Two looks only agree if these match.
    var visibleSpaces: Set<UInt64>?

    static func unsure(_ reason: String) -> Inspection {
        Inspection(verdict: .unsure(reason))
    }
}

/// What the frontmost app looked like at one moment: ⌘W is checked against the state *before*
/// the key press, because by the time we see the key the app may already have closed the window.
struct FocusSnapshot {
    let pid: pid_t
    let realWindows: [AXUIElement]
    /// The focused window, if it is a real window (the one ⌘W is about to close).
    let focusedRealWindow: AXUIElement?
    /// The real windows' close buttons, as seen before any click on them.
    let closeButtons: [KnownCloseButton]
    let takenAt: TimeInterval
}

/// A real window's close button, recorded ahead of any click. A tap on the trackpad delivers the
/// press and the release together, so the app may already be closing the window by the time
/// CloseQuit asks about the button; this still says whose button it was and where.
struct KnownCloseButton {
    let button: AXUIElement
    let window: AXUIElement
    let frame: CGRect
}

final class WindowInspector {
    func inspect(pid: pid_t, closedWindow: AXUIElement?) -> Inspection {
        let spacesBefore = PrivateAPI.visibleSpaceIDs()
        let appElement = AXKit.application(pid)
        let windows: [AXUIElement]
        switch AXKit.elements(appElement, kAXWindowsAttribute) {
        case .value(let list): windows = list
        case .missing: return .unsure("it doesn't list its windows to Accessibility")
        case .gone: return .unsure("it stopped answering Accessibility")
        case .failed(let error): return .unsure("reading its windows failed: \(error.label)")
        }

        var result = Inspection(verdict: .unsure("not checked"))
        result.closedWindowStillOpen = closedWindow == nil ? nil : false
        var accessibilityIDs = Set<UInt32>()

        for window in windows {
            let kind: WindowKind
            let sheets: [AXUIElement]
            do {
                kind = try classify(window)
                sheets = kind.isRealWindow ? try self.sheets(of: window) : []
            } catch AXFailure.gone {
                continue  // destroyed while we were looking: it isn't open
            } catch {
                return .unsure("reading one of its windows failed: \((error as? AXFailure)?.label ?? "unknown error")")
            }

            switch kind {
            case .standard: result.census.standard += 1
            case .ambiguous: result.census.ambiguous += 1
            case .dialog: result.census.dialogs += 1
            case .ignorable: result.census.ignored += 1
            }
            result.census.dialogs += sheets.count
            if kind != .ignorable { result.watchTargets.append(window) }
            result.watchTargets += sheets
            for element in [window] + sheets {
                if let id = PrivateAPI.windowID(of: element) { accessibilityIDs.insert(id) }
            }
            if let closedWindow, CFEqual(window, closedWindow) { result.closedWindowStillOpen = true }
        }

        // Accessibility only lists windows on the Spaces you can see. Ask the window server about the rest.
        guard let allWindows = ServerWindows.all(), allWindows.contains(where: \.isOnscreen) else {
            return .unsure("the window server's window list was unavailable")
        }
        let appWindows = allWindows.filter { $0.ownerPID == pid }
        // Every window Accessibility just reported must be in the window server's list too;
        // if not, that list is incomplete and can't vouch for anything.
        if PrivateAPI.canMapWindows, !accessibilityIDs.isSubset(of: Set(appWindows.map(\.id))) {
            return .unsure("the window server's list looked incomplete")
        }

        let displays = ServerWindows.displayBounds()
        let knownIDs: Set<UInt32>? = PrivateAPI.canMapWindows ? accessibilityIDs : nil
        let stageManager = StageManager.isEnabled
        var spacesNeeded = false
        for var window in appWindows {
            if !window.isOnscreen && ServerWindowPolicy.isSpaceCandidate(window) {
                spacesNeeded = true
                window.spaces = PrivateAPI.spaces(forWindow: window.id)
                if ServerWindowPolicy.isOnHiddenSpace(window, visibleSpaces: spacesBefore) {
                    result.census.onHiddenSpaces += 1
                } else if stageManager, ServerWindowPolicy.isParkedOnVisibleSpace(window, visibleSpaces: spacesBefore),
                          knownIDs?.contains(window.id) != true {
                    result.census.setAside += 1
                }
            } else if window.isOnscreen && ServerWindowPolicy.isUserSized(window),
                      ServerWindowPolicy.isUnaccountedOnscreen(window, accessibilityIDs: knownIDs, displays: displays) {
                result.census.unaccountedOnscreen += 1
            }
        }
        if spacesNeeded && !ServerWindows.spacesLookupWorks(allWindows, visibleSpaces: spacesBefore) {
            return .unsure("couldn't verify which Spaces its windows are on")
        }
        // A Space switch or full-screen animation mid-check would make the two halves disagree.
        guard PrivateAPI.visibleSpaceIDs() == spacesBefore else {
            return .unsure(DecisionPolicy.spacesChangedPhrase)
        }

        result.census.appHidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
        result.visibleSpaces = spacesBefore
        result.verdict = Decider.verdict(result.census)
        return result
    }

    /// The kind of a single window; nil if it can't be read.
    func kind(of window: AXUIElement) -> WindowKind? {
        try? classify(window)
    }

    /// Nil if anything ⌘W needs can't be read: the first failure ends it, so a hung app costs one
    /// timeout. A close button that can't be read is just left out.
    func focusSnapshot(pid: pid_t) -> FocusSnapshot? {
        let appElement = AXKit.application(pid)
        do {
            guard let windows = try AXKit.elements(appElement, kAXWindowsAttribute).get() else { return nil }
            var realWindows: [AXUIElement] = []
            for window in windows {
                do {
                    if try classify(window).isRealWindow { realWindows.append(window) }
                } catch AXFailure.gone {
                    continue
                }
            }
            var focusedRealWindow: AXUIElement?
            if let focused = try AXKit.element(appElement, kAXFocusedWindowAttribute).get(),
               (try? classify(focused))?.isRealWindow == true {
                focusedRealWindow = focused
            }
            // Read last, so the part ⌘W relies on is taken as close to the ⌘ press as possible.
            var closeButtons: [KnownCloseButton] = []
            for window in realWindows {
                let read = closeButton(of: window)
                if case .failed = read { break }  // a slow app costs one timeout, not one per window
                if let known = read.value { closeButtons.append(known) }
            }
            return FocusSnapshot(pid: pid, realWindows: realWindows, focusedRealWindow: focusedRealWindow,
                                 closeButtons: closeButtons, takenAt: Engine.now)
        } catch {
            return nil
        }
    }

    private func closeButton(of window: AXUIElement) -> AXRead<KnownCloseButton> {
        let button = AXKit.element(window, kAXCloseButtonAttribute)
        guard case .value(let element) = button else { return button.cast { _ in nil } }
        return AXKit.frame(of: element).cast { KnownCloseButton(button: element, window: window, frame: $0) }
    }

    private func classify(_ window: AXUIElement) throws -> WindowKind {
        var traits = WindowTraits(role: try AXKit.string(window, kAXRoleAttribute).get(),
                                  subrole: try AXKit.string(window, kAXSubroleAttribute).get())
        if WindowClassifier.needsShape(traits) {
            traits.isMinimized = try AXKit.bool(window, kAXMinimizedAttribute).get() ?? false
            traits.size = try AXKit.size(of: window).get()
        }
        return WindowClassifier.classify(traits)
    }

    /// Sheets attached to a window ("Save changes?" and friends) show up as AXSheet children.
    private func sheets(of window: AXUIElement) throws -> [AXUIElement] {
        guard let children = try AXKit.elements(window, kAXChildrenAttribute).get() else { return [] }
        var sheets: [AXUIElement] = []
        for child in children.prefix(100) {
            do {
                if try AXKit.string(child, kAXRoleAttribute).get() == kAXSheetRole { sheets.append(child) }
            } catch AXFailure.gone {
                continue
            }
        }
        return sheets
    }
}

enum ServerWindows {
    /// Every window the window server knows, on or off screen, without Spaces filled in;
    /// nil if the list is unavailable.
    static func all() -> [ServerWindow]? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return list.compactMap { info in
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { return nil }
            return ServerWindow(id: id,
                                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                                bounds: bounds,
                                isOnscreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                                spaces: nil,
                                ownerPID: owner)
        }
    }

    /// The undocumented Spaces lookup still works if an on-screen window (the desktop picture,
    /// the menu bar) reports one of the visible Spaces.
    static func spacesLookupWorks(_ windows: [ServerWindow], visibleSpaces: Set<UInt64>?) -> Bool {
        var samples: [[UInt64]] = []
        for window in windows where window.isOnscreen {
            guard let spaces = PrivateAPI.spaces(forWindow: window.id) else { continue }
            samples.append(spaces)
            if ServerWindowPolicy.spacesLookupLooksHealthy(onscreenWindowSpaces: samples, visibleSpaces: visibleSpaces) {
                return true
            }
            if samples.count >= 24 { break }
        }
        return false
    }

    /// Display frames in global coordinates (top-left origin, like window bounds).
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }
}

enum StageManager {
    private static let defaults = UserDefaults(suiteName: "com.apple.WindowManager")

    /// With Stage Manager on, a window off to the side may look like a hidden one, so those
    /// count as "unsure" instead of "closed".
    static var isEnabled: Bool {
        defaults?.bool(forKey: "GloballyEnabled") ?? false
    }
}
