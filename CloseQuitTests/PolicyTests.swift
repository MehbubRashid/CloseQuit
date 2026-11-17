//
//  PolicyTests.swift
//  CloseQuitTests
//
//  The rules in CloseQuit/Core/Policy.swift. Most tests check the "leave it alone" side,
//  because quitting an app the user didn't close is the one thing CloseQuit must never do.
//

import CoreGraphics
import XCTest

final class ShortcutMatcherTests: XCTestCase {
    private func matches(_ keyCode: Int64, _ flags: CGEventFlags, _ text: String?) -> Bool {
        ShortcutMatcher.isPlainCommandW(keyCode: keyCode, flags: flags, characters: text)
    }

    func testPlainCommandWMatches() {
        XCTAssertTrue(matches(13, .maskCommand, "w"))
        // Caps Lock and the left/right-⌘ device bits don't change the shortcut.
        XCTAssertTrue(matches(13, [.maskCommand, .maskAlphaShift], "W"))
        XCTAssertTrue(matches(13, CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08), "w"))
    }

    func testOtherModifiersDontMatch() {
        XCTAssertFalse(matches(13, [.maskCommand, .maskShift], "w"))
        XCTAssertFalse(matches(13, [.maskCommand, .maskAlternate], "w"))
        XCTAssertFalse(matches(13, [.maskCommand, .maskControl], "w"))
        XCTAssertFalse(matches(13, [.maskCommand, .maskSecondaryFn], "w"))
        XCTAssertFalse(matches(13, [], "w"))
        XCTAssertFalse(matches(12, .maskCommand, "q"))  // ⌘Q
    }

    func testKey13ThatDoesntTypeWDoesntMatch() {
        XCTAssertFalse(matches(13, .maskCommand, "z"))  // AZERTY: ⌘Z is Undo
        XCTAssertFalse(matches(13, .maskCommand, ","))  // Dvorak: ⌘, is Settings
        XCTAssertFalse(matches(13, .maskCommand, ""))
        XCTAssertFalse(matches(13, .maskCommand, nil))
    }

    func testChordCheckIgnoresText() {
        XCTAssertTrue(ShortcutMatcher.isCommandWChord(keyCode: 13, flags: .maskCommand))
        XCTAssertFalse(ShortcutMatcher.isCommandWChord(keyCode: 13, flags: [.maskCommand, .maskShift]))
    }
}

final class ClickPolicyTests: XCTestCase {
    private let button = CGRect(x: 100, y: 50, width: 14, height: 16)

    func testReleaseInsideConfirms() {
        XCTAssertTrue(ClickPolicy.releaseConfirmsClose(buttonFrame: button, releaseLocation: CGPoint(x: 107, y: 58)))
    }

    func testReleaseOnTheEdgeConfirms() {
        XCTAssertTrue(ClickPolicy.releaseConfirmsClose(buttonFrame: button, releaseLocation: CGPoint(x: 114, y: 66)))
        XCTAssertTrue(ClickPolicy.releaseConfirmsClose(buttonFrame: button, releaseLocation: CGPoint(x: 100, y: 50)))
    }

    func testDraggingAwayCancels() {
        XCTAssertFalse(ClickPolicy.releaseConfirmsClose(buttonFrame: button, releaseLocation: CGPoint(x: 140, y: 58)))
        XCTAssertFalse(ClickPolicy.releaseConfirmsClose(buttonFrame: button, releaseLocation: CGPoint(x: 107, y: 90)))
        XCTAssertFalse(ClickPolicy.releaseConfirmsClose(buttonFrame: button, releaseLocation: CGPoint(x: 114.5, y: 58)))
    }

    func testEmptyFrameNeverConfirms() {
        XCTAssertFalse(ClickPolicy.releaseConfirmsClose(buttonFrame: .zero, releaseLocation: .zero))
    }

    func testControlClickIsIgnored() {
        XCTAssertTrue(ClickPolicy.ignoresMouseDown(flags: .maskControl))
        XCTAssertFalse(ClickPolicy.ignoresMouseDown(flags: []))
        XCTAssertFalse(ClickPolicy.ignoresMouseDown(flags: .maskAlternate))  // ⌥-click closes all windows: still a close
    }
}

final class WindowClassifierTests: XCTestCase {
    private func kind(_ role: String?, _ subrole: String?, minimized: Bool = false, size: CGSize? = nil) -> WindowKind {
        WindowClassifier.classify(WindowTraits(role: role, subrole: subrole, isMinimized: minimized, size: size))
    }

    func testStandardWindowsAreReal() {
        XCTAssertEqual(kind("AXWindow", "AXStandardWindow"), .standard)
        XCTAssertEqual(kind("AXWindow", "AXStandardWindow", minimized: true), .standard)
    }

    func testSheetsAndDialogs() {
        XCTAssertEqual(kind("AXSheet", nil), .dialog)
        XCTAssertEqual(kind("AXWindow", "AXDialog"), .dialog)
        XCTAssertEqual(kind("AXWindow", "AXSystemDialog"), .dialog)
    }

    func testPanelsAndPopoversAreIgnored() {
        XCTAssertEqual(kind("AXWindow", "AXFloatingWindow"), .ignorable)
        XCTAssertEqual(kind("AXWindow", "AXSystemFloatingWindow"), .ignorable)
        XCTAssertEqual(kind("AXPopover", nil), .ignorable)
    }

    func testUnrecognisedWindowsCountAsReal() {
        XCTAssertEqual(kind("AXWindow", "AXUnknown", size: CGSize(width: 800, height: 600)), .ambiguous)
        XCTAssertEqual(kind("AXWindow", nil, size: nil), .ambiguous)          // size unknown: assume real
        XCTAssertEqual(kind(nil, nil, size: CGSize(width: 400, height: 300)), .ambiguous)
        XCTAssertEqual(kind("AXWindow", "AXUnknown", minimized: true, size: CGSize(width: 10, height: 10)), .ambiguous)
    }

    func testTinyUnrecognisedWindowsAreIgnored() {
        XCTAssertEqual(kind("AXWindow", "AXUnknown", size: CGSize(width: 40, height: 40)), .ignorable)
    }

    func testOnlyUnrecognisedWindowsNeedTheirShape() {
        XCTAssertFalse(WindowClassifier.needsShape(WindowTraits(role: "AXWindow", subrole: "AXStandardWindow")))
        XCTAssertFalse(WindowClassifier.needsShape(WindowTraits(role: "AXSheet", subrole: nil)))
        XCTAssertTrue(WindowClassifier.needsShape(WindowTraits(role: "AXWindow", subrole: "AXUnknown")))
        XCTAssertTrue(WindowClassifier.needsShape(WindowTraits(role: nil, subrole: nil)))
    }
}

final class ServerWindowPolicyTests: XCTestCase {
    private func window(onscreen: Bool, spaces: [UInt64]?, size: CGSize = CGSize(width: 800, height: 600),
                        layer: Int = 0, alpha: Double = 1, id: UInt32 = 7) -> ServerWindow {
        ServerWindow(id: id, layer: layer, alpha: alpha, bounds: CGRect(origin: .init(x: 10, y: 40), size: size),
                     isOnscreen: onscreen, spaces: spaces)
    }

    func testUserSized() {
        XCTAssertTrue(ServerWindowPolicy.isUserSized(window(onscreen: true, spaces: nil)))
        XCTAssertFalse(ServerWindowPolicy.isUserSized(window(onscreen: true, spaces: nil, layer: 25)))   // menu bar level
        XCTAssertFalse(ServerWindowPolicy.isUserSized(window(onscreen: true, spaces: nil, alpha: 0)))
        XCTAssertFalse(ServerWindowPolicy.isUserSized(window(onscreen: true, spaces: nil, size: CGSize(width: 1728, height: 33))))
    }

    func testSpaceCandidatesIncludeFloatingAndTransparentWindows() {
        XCTAssertTrue(ServerWindowPolicy.isSpaceCandidate(window(onscreen: false, spaces: nil, layer: 3)))   // Float on Top
        XCTAssertTrue(ServerWindowPolicy.isSpaceCandidate(window(onscreen: false, spaces: nil, alpha: 0)))
        XCTAssertTrue(ServerWindowPolicy.isSpaceCandidate(window(onscreen: false, spaces: nil, size: CGSize(width: 1728, height: 33))))
        XCTAssertFalse(ServerWindowPolicy.isSpaceCandidate(window(onscreen: false, spaces: nil, layer: 25)))  // status item
        XCTAssertFalse(ServerWindowPolicy.isSpaceCandidate(window(onscreen: false, spaces: nil, size: CGSize(width: 1, height: 1))))
    }

    func testFloatOnTopWindowOnAnotherSpaceBlocks() {
        let pinned = window(onscreen: false, spaces: [42], layer: 3)
        XCTAssertTrue(ServerWindowPolicy.isSpaceCandidate(pinned))
        XCTAssertTrue(ServerWindowPolicy.isOnHiddenSpace(pinned, visibleSpaces: [1, 3910]))
    }

    func testWindowOnAnotherSpaceBlocks() {
        XCTAssertTrue(ServerWindowPolicy.isOnHiddenSpace(window(onscreen: false, spaces: [42]), visibleSpaces: [1, 3910]))
    }

    func testHiddenWindowOnCurrentSpaceDoesNotBlock() {
        // Hide-on-close apps order their window out but it stays assigned to the current Space.
        XCTAssertFalse(ServerWindowPolicy.isOnHiddenSpace(window(onscreen: false, spaces: [1]), visibleSpaces: [1, 3910]))
    }

    func testNeverShownWindowDoesNotBlock() {
        XCTAssertFalse(ServerWindowPolicy.isOnHiddenSpace(window(onscreen: false, spaces: []), visibleSpaces: [1]))
    }

    func testUnknownSpacesBlock() {
        XCTAssertTrue(ServerWindowPolicy.isOnHiddenSpace(window(onscreen: false, spaces: nil), visibleSpaces: [1]))
        XCTAssertTrue(ServerWindowPolicy.isOnHiddenSpace(window(onscreen: false, spaces: [1]), visibleSpaces: nil))
    }

    func testOnscreenWindowsAreNotOnHiddenSpaces() {
        XCTAssertFalse(ServerWindowPolicy.isOnHiddenSpace(window(onscreen: true, spaces: [42]), visibleSpaces: [1]))
    }

    func testParkedOnVisibleSpace() {
        XCTAssertTrue(ServerWindowPolicy.isParkedOnVisibleSpace(window(onscreen: false, spaces: [1]), visibleSpaces: [1, 3910]))
        XCTAssertFalse(ServerWindowPolicy.isParkedOnVisibleSpace(window(onscreen: false, spaces: [42]), visibleSpaces: [1]))
        XCTAssertFalse(ServerWindowPolicy.isParkedOnVisibleSpace(window(onscreen: false, spaces: []), visibleSpaces: [1]))
        XCTAssertFalse(ServerWindowPolicy.isParkedOnVisibleSpace(window(onscreen: true, spaces: [1]), visibleSpaces: [1]))
        XCTAssertFalse(ServerWindowPolicy.isParkedOnVisibleSpace(window(onscreen: false, spaces: [1]), visibleSpaces: nil))
    }

    func testSpacesLookupHealthCheck() {
        XCTAssertTrue(ServerWindowPolicy.spacesLookupLooksHealthy(onscreenWindowSpaces: [[], [3910]], visibleSpaces: [1, 3910]))
        XCTAssertFalse(ServerWindowPolicy.spacesLookupLooksHealthy(onscreenWindowSpaces: [[], []], visibleSpaces: [1]))
        XCTAssertFalse(ServerWindowPolicy.spacesLookupLooksHealthy(onscreenWindowSpaces: [], visibleSpaces: [1]))
        XCTAssertFalse(ServerWindowPolicy.spacesLookupLooksHealthy(onscreenWindowSpaces: [[42]], visibleSpaces: [1]))
        XCTAssertFalse(ServerWindowPolicy.spacesLookupLooksHealthy(onscreenWindowSpaces: [[1]], visibleSpaces: nil))
    }

    func testUnaccountedOnscreenWindow() {
        let displays = [CGRect(x: 0, y: 0, width: 1728, height: 1117)]
        let visible = window(onscreen: true, spaces: nil, id: 7)
        XCTAssertFalse(ServerWindowPolicy.isUnaccountedOnscreen(visible, accessibilityIDs: [7], displays: displays))
        XCTAssertTrue(ServerWindowPolicy.isUnaccountedOnscreen(visible, accessibilityIDs: [8], displays: displays))
        XCTAssertTrue(ServerWindowPolicy.isUnaccountedOnscreen(visible, accessibilityIDs: nil, displays: displays))
        XCTAssertTrue(ServerWindowPolicy.isUnaccountedOnscreen(visible, accessibilityIDs: [8], displays: []))
        XCTAssertFalse(ServerWindowPolicy.isUnaccountedOnscreen(window(onscreen: false, spaces: [1]),
                                                                accessibilityIDs: [], displays: displays))
        let parkedOffscreen = ServerWindow(id: 9, layer: 0, alpha: 1, bounds: CGRect(x: -9000, y: -9000, width: 800, height: 600),
                                           isOnscreen: true, spaces: nil)
        XCTAssertFalse(ServerWindowPolicy.isUnaccountedOnscreen(parkedOffscreen, accessibilityIDs: [], displays: displays))
    }
}

final class DeciderTests: XCTestCase {
    func testOnlyAnEmptyCensusMeansNoWindows() {
        XCTAssertEqual(Decider.verdict(WindowCensus()), .noWindowsLeft)
        XCTAssertEqual(Decider.verdict(WindowCensus(ignored: 3)), .noWindowsLeft)  // palettes don't keep an app alive
    }

    func testRealWindowsRemain() {
        XCTAssertEqual(Decider.verdict(WindowCensus(standard: 2)), .windowsRemain(count: 2, dialog: false))
        XCTAssertEqual(Decider.verdict(WindowCensus(ambiguous: 1)), .windowsRemain(count: 1, dialog: false))
        XCTAssertEqual(Decider.verdict(WindowCensus(standard: 1, dialogs: 1)), .windowsRemain(count: 1, dialog: true))
    }

    func testDialogOnly() {
        XCTAssertEqual(Decider.verdict(WindowCensus(dialogs: 1)), .dialogOnly)
    }

    func testDoubtMeansUnsure() {
        for census in [WindowCensus(onHiddenSpaces: 1), WindowCensus(unaccountedOnscreen: 1),
                       WindowCensus(setAside: 1), WindowCensus(appHidden: true)] {
            guard case .unsure = Decider.verdict(census) else { return XCTFail("\(census) should be unsure") }
        }
    }
}

final class DecisionPolicyTests: XCTestCase {
    func testNoWindowsIsCheckedTwiceBeforeQuitting() {
        XCTAssertEqual(DecisionPolicy.afterFirstLook(.noWindowsLeft, closedWindowStillOpen: false), .recheck)
        XCTAssertEqual(DecisionPolicy.afterRecheck(.noWindowsLeft, spacesUnchanged: true), .quit)
    }

    func testSpacesChangingBetweenLooksCancels() {
        XCTAssertEqual(DecisionPolicy.afterRecheck(.noWindowsLeft, spacesUnchanged: false),
                       .stop(DecisionPolicy.spacesChangedPhrase))
    }

    func testAWindowComingBackCancels() {
        XCTAssertEqual(DecisionPolicy.afterRecheck(.windowsRemain(count: 1, dialog: false), spacesUnchanged: true),
                       .stop("a window came back"))
        XCTAssertEqual(DecisionPolicy.afterRecheck(.windowsRemain(count: 1, dialog: true), spacesUnchanged: true),
                       .stop("a window came back"))
    }

    func testDialogsStartTheLongWatch() {
        XCTAssertEqual(DecisionPolicy.afterFirstLook(.windowsRemain(count: 1, dialog: true), closedWindowStillOpen: true),
                       .watch(dialog: true))
        XCTAssertEqual(DecisionPolicy.afterFirstLook(.dialogOnly, closedWindowStillOpen: nil), .watch(dialog: true))
        XCTAssertEqual(DecisionPolicy.afterRecheck(.dialogOnly, spacesUnchanged: true), .watch(dialog: true))
    }

    func testOtherWindowsOpenMeansStop() {
        XCTAssertEqual(DecisionPolicy.afterFirstLook(.windowsRemain(count: 2, dialog: false), closedWindowStillOpen: false),
                       .stop("2 windows are still open"))
        XCTAssertEqual(DecisionPolicy.afterFirstLook(.windowsRemain(count: 1, dialog: false), closedWindowStillOpen: nil),
                       .stop("1 window is still open"))
    }

    func testASheetOnAnotherWindowDoesntStartAWatch() {
        // The closed window is gone; a different window has a sheet. It wasn't the last window.
        XCTAssertEqual(DecisionPolicy.afterFirstLook(.windowsRemain(count: 2, dialog: true), closedWindowStillOpen: false),
                       .stop("2 windows are still open"))
    }

    func testClosedWindowStillThereGetsAShortGrace() {
        XCTAssertEqual(DecisionPolicy.afterFirstLook(.windowsRemain(count: 1, dialog: false), closedWindowStillOpen: true),
                       .watch(dialog: false))
    }

    func testUnsureAlwaysStops() {
        XCTAssertEqual(DecisionPolicy.afterFirstLook(.unsure("x"), closedWindowStillOpen: true), .stop("x"))
        XCTAssertEqual(DecisionPolicy.afterRecheck(.unsure("y"), spacesUnchanged: true), .stop("y"))
        XCTAssertEqual(DecisionPolicy.afterRecheck(.unsure("z"), spacesUnchanged: false), .stop("z"))
    }
}

final class WatchPolicyTests: XCTestCase {
    func testDialogWatchLasts30SecondsFromTheClose() {
        let state = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(state.deadline, 130)
        XCTAssertTrue(state.dialogSeen)
    }

    func testLastWindowClosingAfterTheDialogQuits() {
        var state = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(WatchPolicy.evaluate(.noWindowsLeft, closedWindowStillOpen: false, state: &state, now: 112), .recheck)
        XCTAssertEqual(WatchPolicy.afterRecheck(.noWindowsLeft, closedWindowStillOpen: false, spacesUnchanged: true,
                                                state: &state, now: 112.3), .quit)
    }

    func testRecheckRequiresTheSameSpaces() {
        var state = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(WatchPolicy.afterRecheck(.noWindowsLeft, closedWindowStillOpen: false, spacesUnchanged: false,
                                                state: &state, now: 112.3),
                       .stop(DecisionPolicy.spacesChangedPhrase))
    }

    func testLateRecheckDoesntQuit() {
        var state = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(WatchPolicy.afterRecheck(.noWindowsLeft, closedWindowStillOpen: false, spacesUnchanged: true,
                                                state: &state, now: 132),
                       .stop("its window was still open after 30 s"))
    }

    func testRecheckThatFindsAWindowKeepsWatching() {
        var state = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(WatchPolicy.afterRecheck(.windowsRemain(count: 1, dialog: true), closedWindowStillOpen: true,
                                                spacesUnchanged: true, state: &state, now: 105),
                       .keepWatching(lookAgainAt: nil))
    }

    func testNothingHappensAfterTheDeadline() {
        var state = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(WatchPolicy.evaluate(.windowsRemain(count: 1, dialog: true), closedWindowStillOpen: true,
                                            state: &state, now: 130.1),
                       .stop("its window was still open after 30 s"))
        var late = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(WatchPolicy.evaluate(.noWindowsLeft, closedWindowStillOpen: false, state: &late, now: 131),
                       .stop("its window was still open after 30 s"))
    }

    func testCancelledDialogStopsAfterGrace() {
        var state = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(WatchPolicy.evaluate(.windowsRemain(count: 1, dialog: false), closedWindowStillOpen: true,
                                            state: &state, now: 104), .keepWatching(lookAgainAt: 109))
        XCTAssertEqual(WatchPolicy.evaluate(.windowsRemain(count: 1, dialog: false), closedWindowStillOpen: true,
                                            state: &state, now: 109),
                       .stop("the dialog was dismissed and the window stayed open"))
    }

    func testANewDialogResetsTheCancelGrace() {
        var state = WatchPolicy.start(actionTime: 100, dialog: true)
        _ = WatchPolicy.evaluate(.windowsRemain(count: 1, dialog: false), closedWindowStillOpen: true, state: &state, now: 104)
        // "Save…" replaced the alert with a save panel.
        _ = WatchPolicy.evaluate(.windowsRemain(count: 1, dialog: true), closedWindowStillOpen: true, state: &state, now: 105)
        XCTAssertNil(state.dialogGoneSince)
        XCTAssertEqual(WatchPolicy.evaluate(.windowsRemain(count: 1, dialog: false), closedWindowStillOpen: true,
                                            state: &state, now: 120), .keepWatching(lookAgainAt: 125))
    }

    func testClosedWindowGoneButOthersOpenStops() {
        var state = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(WatchPolicy.evaluate(.windowsRemain(count: 2, dialog: false), closedWindowStillOpen: false,
                                            state: &state, now: 103),
                       .stop("2 windows are still open"))
        // Even if another window happens to show a sheet.
        var other = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(WatchPolicy.evaluate(.windowsRemain(count: 1, dialog: true), closedWindowStillOpen: false,
                                            state: &other, now: 103),
                       .stop("1 window is still open"))
    }

    func testGraceWatchBecomesDialogWatchWhenADialogAppears() {
        var state = WatchPolicy.start(actionTime: 100, dialog: false)
        XCTAssertEqual(state.deadline, 103)
        XCTAssertEqual(WatchPolicy.evaluate(.windowsRemain(count: 1, dialog: true), closedWindowStillOpen: true,
                                            state: &state, now: 101), .keepWatching(lookAgainAt: nil))
        XCTAssertEqual(state.deadline, 130)
    }

    func testGraceWatchEndsQuietlyIfTheWindowNeverCloses() {
        var state = WatchPolicy.start(actionTime: 100, dialog: false)
        XCTAssertEqual(WatchPolicy.evaluate(.windowsRemain(count: 1, dialog: false), closedWindowStillOpen: true,
                                            state: &state, now: 101), .keepWatching(lookAgainAt: nil))
        XCTAssertEqual(WatchPolicy.evaluate(.windowsRemain(count: 1, dialog: false), closedWindowStillOpen: true,
                                            state: &state, now: 103), .stop("its window didn't close"))
    }

    func testUnsureStopsTheWatch() {
        var state = WatchPolicy.start(actionTime: 100, dialog: true)
        XCTAssertEqual(WatchPolicy.evaluate(.unsure("it still has a window on another Space"), closedWindowStillOpen: false,
                                            state: &state, now: 101), .stop("it still has a window on another Space"))
    }
}

final class DenylistTests: XCTestCase {
    func testFinderIsNeverManaged() {
        XCTAssertTrue(Denylist.contains("com.apple.finder"))
        XCTAssertFalse(Denylist.contains("com.apple.Safari"))
    }
}
