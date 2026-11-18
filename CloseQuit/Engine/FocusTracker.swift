//
//  FocusTracker.swift
//  CloseQuit
//
//  Keeps a snapshot of the frontmost allowed app ("which real windows does it have, which
//  one is focused, where are their close buttons"), refreshed by AXObserver notifications and
//  on every ⌘ press, never by polling. ⌘W is only acted on if a snapshot taken after ⌘ went down
//  says a real window was open, so ⌘W in an app with no windows (or with only a palette focused)
//  never quits it. The close buttons let a tap on the trackpad count even when the app starts
//  closing the window before CloseQuit can look at it. Engine.queue only.
//

import ApplicationServices
import Foundation

final class FocusTracker {
    private let inspector: WindowInspector
    private var pid: pid_t = 0
    private var token: Int?
    private var subscribed = false
    private var refreshPending = false
    /// The app we're waiting on to start answering Accessibility after its launch, if any.
    private var awaitingAnswerFrom: pid_t = 0
    /// Windows we've asked to hear about when they're destroyed.
    private var observedWindows: [AXUIElement] = []

    private(set) var snapshot: FocusSnapshot?

    init(inspector: WindowInspector) {
        self.inspector = inspector
    }

    /// Start following `newPID` (nil to stop).
    func track(_ newPID: pid_t?) {
        let target = newPID ?? 0
        guard target != pid else {
            if target != 0 { refreshNow() }
            return
        }
        unsubscribe()
        pid = target
        snapshot = nil
        guard target != 0 else { return }
        subscribe()
        refreshNow()
    }

    /// ⌘ went down: take a fresh snapshot. It's queued ahead of any ⌘W that follows, so the
    /// worst it can do is see a window already closed and make CloseQuit more cautious.
    func commandPressed() {
        guard pid != 0 else { return }
        catchUp()
    }

    /// `launchedPID` has finished launching. An app that is still starting up doesn't answer
    /// Accessibility, so subscribing fails when it first comes to the front, and without the
    /// subscription its close buttons go unrecorded. It starts answering a moment after it
    /// finishes launching: wait for that off the engine queue, then subscribe again.
    func appFinishedLaunching(_ launchedPID: pid_t) {
        guard launchedPID == pid, pid != 0, !subscribed, awaitingAnswerFrom != pid else { return }
        let target = pid
        awaitingAnswerFrom = target
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let element = AXUIElementCreateApplication(target)
            AXUIElementSetMessagingTimeout(element, 5)
            var role: CFTypeRef?
            let answered = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
            Engine.queue.async {
                guard let self else { return }
                if self.awaitingAnswerFrom == target { self.awaitingAnswerFrom = 0 }
                if answered, self.pid == target { self.catchUp() }
            }
        }
    }

    func forget(_ endedPID: pid_t) {
        if endedPID == pid { track(nil) }
    }

    /// `button`'s record, if it is the close button of one of the tracked app's real windows.
    func knownCloseButton(_ button: AXUIElement) -> KnownCloseButton? {
        snapshot?.closeButtons.first { CFEqual($0.button, button) }
    }

    private func subscribe() {
        let target = pid
        guard let token = AXObserverCenter.shared.add(pid: target, handler: { [weak self] _, _ in
            self?.scheduleRefresh(for: target)
        }) else {
            subscribed = false
            return
        }
        self.token = token
        let appElement = AXKit.application(target)
        let results = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
                       // A window that moves or changes size takes its close button with it.
                       kAXWindowMovedNotification, kAXWindowResizedNotification]
            .map { AXObserverCenter.shared.register(token, $0, on: appElement) }
        subscribed = results.contains { $0 == .success || $0 == .notificationAlreadyRegistered }
    }

    /// Subscribe again if that failed before, and take a fresh snapshot.
    private func catchUp() {
        if !subscribed {
            unsubscribe()
            subscribe()
        }
        refreshNow()
    }

    private func unsubscribe() {
        if let token { AXObserverCenter.shared.remove(token) }
        token = nil
        subscribed = false
        observedWindows = []
    }

    private func scheduleRefresh(for target: pid_t) {
        guard target == pid, !refreshPending else { return }
        refreshPending = true
        Engine.queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            if self.pid == target { self.refreshNow() }
        }
    }

    private func refreshNow() {
        snapshot = inspector.focusSnapshot(pid: pid)
        observeDestruction(of: snapshot?.realWindows ?? [])
    }

    /// A window closing without a focus change (File ▸ Close on a background window, the app
    /// closing it itself) still refreshes the snapshot, so it doesn't keep claiming a window.
    private func observeDestruction(of windows: [AXUIElement]) {
        guard let token else { return }
        var stillOpen = observedWindows.filter { observed in windows.contains { CFEqual($0, observed) } }
        for window in windows where !stillOpen.contains(where: { CFEqual($0, window) }) {
            let result = AXObserverCenter.shared.register(token, kAXUIElementDestroyedNotification, on: window)
            if result == .success || result == .notificationAlreadyRegistered { stillOpen.append(window) }
        }
        observedWindows = stillOpen
    }
}
