//
//  FocusTracker.swift
//  CloseQuit
//
//  Keeps a snapshot of the frontmost allowed app ("which real windows does it have, which
//  one is focused"), refreshed by AXObserver notifications and on every ⌘ press, never by
//  polling. ⌘W is only acted on if a snapshot taken after ⌘ went down says a real window was
//  open, so ⌘W in an app with no windows (or with only a palette focused) never quits it.
//  Engine.queue only.
//

import ApplicationServices
import Foundation

final class FocusTracker {
    private let inspector: WindowInspector
    private var pid: pid_t = 0
    private var token: Int?
    private var subscribed = false
    private var refreshPending = false
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
        if !subscribed {
            unsubscribe()
            subscribe()
        }
        refreshNow()
    }

    func forget(_ endedPID: pid_t) {
        if endedPID == pid { track(nil) }
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
        let results = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification]
            .map { AXObserverCenter.shared.register(token, $0, on: appElement) }
        subscribed = results.contains { $0 == .success || $0 == .notificationAlreadyRegistered }
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
