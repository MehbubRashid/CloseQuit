//
//  CloseMonitor.swift
//  CloseQuit
//
//  Turns explicit close actions into quit decisions. Nothing here polls: every decision
//  starts from a click on a close button or a ⌘W the user made.
//
//  One action, start to finish:
//    1. Detect it: a close button pressed *and released* on the same button, or a plain ⌘W
//       delivered to the frontmost app, which must be on the user's list.
//    2. Wait `checkDelay` (400 ms by default) and look at the app's windows.
//    3. No windows left → look again 300 ms later → still none → NSRunningApplication.terminate().
//    4. A sheet or dialog is up ("Save changes?") → watch the app with an AXObserver for up to
//       30 s and quit only if its last window then goes away.
//    Anything unexpected along the way (an error, a timeout, a window on another Space)
//    ends the attempt and leaves the app running.
//

import AppKit
import ApplicationServices
import os

enum MonitorStatus: Equatable {
    case paused
    case needsAccessibility
    case running
    case failed(String)
}

struct EngineConfig: Equatable {
    var enabled = true
    var commandW = true
    var checkDelay: TimeInterval = 0.4
    var allowlist: Set<String> = []
}

enum ActivityKind {
    case quit, kept, waiting, ignored, problem
}

/// The app the user acted on, pinned to one process launch so a recycled PID can't stand in for it.
struct AppIdentity {
    let pid: pid_t
    let bundleID: String
    let name: String
    let launchDate: Date?

    var isStillRunning: Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated && app.bundleIdentifier == bundleID && app.launchDate == launchDate
    }
}

enum CloseSource {
    case closeButton, commandW

    var label: String {
        switch self {
        case .closeButton: return "close button"
        case .commandW: return "⌘W"
        }
    }
}

struct CloseAction {
    let id: UInt64
    let app: AppIdentity
    let source: CloseSource
    /// The window that was closed, when known: tells "still closing" apart from "another window is open".
    let closedWindow: AXUIElement?
    let time: TimeInterval
}

final class CloseMonitor {
    /// Called on the main thread.
    typealias Reporter = (ActivityKind, String) -> Void

    private let reportOnMain: Reporter
    private let inspector = WindowInspector()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CloseQuit", category: "engine")
    private lazy var focus = FocusTracker(inspector: inspector)
    private lazy var tap = EventTap { [weak self] event in
        Engine.queue.async { self?.handle(event) }
    }

    // Engine.queue state.
    private var config = EngineConfig()
    private var monitoring = false
    private var frontmostPID: pid_t = 0
    private var clickNumber: UInt64 = 0
    private var pendingClick: PendingClick?
    private var commandIsDown = false
    private var commandDownAt: TimeInterval = .infinity
    private var lastActionID: UInt64 = 0
    private var liveActions: [pid_t: CloseAction] = [:]
    private var watches: [pid_t: Watch] = [:]

    /// The settings as last set on the main thread, so the final quit can re-check them there.
    private let latestConfig = OSAllocatedUnfairLock(initialState: EngineConfig())

    // Main thread.
    private var workspaceObservers: [NSObjectProtocol] = []

    /// A mouse-down on an allowed app's close button, waiting for its mouse-up.
    private struct PendingClick {
        let number: UInt64
        let app: AppIdentity
        let button: AXUIElement
        let buttonFrame: CGRect
        let window: AXUIElement
    }

    /// An app we're keeping an eye on after a close (save dialog, or a window still closing).
    private final class Watch {
        let action: CloseAction
        var state: WatchState
        var token: Int?
        var observed: [AXUIElement] = []
        var changePending = false
        var recheckPending = false
        /// The visible Spaces at the look that asked for a recheck; the recheck must see the same.
        var recheckSpaces: Set<UInt64>?
        var deadlineScheduled: TimeInterval = 0
        var graceCheckScheduled: TimeInterval?

        init(action: CloseAction, state: WatchState) {
            self.action = action
            self.state = state
        }
    }

    init(report: @escaping Reporter) {
        reportOnMain = report
        _ = AXKit.systemWide  // applies the 0.5 s Accessibility timeout process-wide
        observeWorkspace()
    }

    // MARK: - Control (call on the main thread)

    func update(_ newConfig: EngineConfig, accessibilityGranted: Bool, completion: @escaping (MonitorStatus) -> Void) {
        latestConfig.withLock { $0 = newConfig }
        Engine.queue.async { [self] in
            let allowlistChanged = newConfig.allowlist != config.allowlist
            let commandWChanged = newConfig.commandW != config.commandW
            config = newConfig

            let status: MonitorStatus
            if !newConfig.enabled {
                stopMonitoring()
                status = .paused
            } else if !accessibilityGranted {
                stopMonitoring()
                status = .needsAccessibility
            } else if startMonitoring() {
                status = .running
            } else {
                status = .failed("macOS wouldn't let CloseQuit watch clicks and keys. In Privacy & Security ▸ Accessibility, remove CloseQuit, add it again, then reopen it.")
            }

            if allowlistChanged { dropWorkForRemovedApps() }
            if allowlistChanged || commandWChanged { updateFocusTracking() }
            DispatchQueue.main.async { completion(status) }
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Engine.queue.async { self?.frontmostChanged(to: pid) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Engine.queue.async { self?.processEnded(pid) }
        })
        // Sleep, a locked screen or another user taking over: nothing that happens to windows
        // afterwards can be the close the user just made, so drop everything in flight.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let reason = note.name.rawValue
                Engine.queue.async { self?.dropEverything(because: reason) }
            })
        }
        workspaceObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Engine.queue.async { self?.dropEverything(because: "screen locked") }
        })
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        Engine.queue.async { [weak self] in self?.frontmostChanged(to: pid) }
    }

    // MARK: - Monitoring on/off (Engine.queue)

    private func startMonitoring() -> Bool {
        if monitoring { return true }
        let tap = self.tap
        let thread = Engine.thread
        guard thread.sync({ tap.install(on: thread.runLoop) }) else {
            log.error("Couldn't create the event tap")
            return false
        }
        monitoring = true
        updateFocusTracking()
        log.info("Monitoring started")
        return true
    }

    private func stopMonitoring() {
        guard monitoring else { return }
        let tap = self.tap
        let thread = Engine.thread
        thread.sync { tap.uninstall(from: thread.runLoop) }
        monitoring = false
        dropEverything(because: "monitoring stopped")
        focus.track(nil)
        log.info("Monitoring stopped")
    }

    /// Forget every pending click, check and watch.
    private func dropEverything(because reason: String) {
        pendingClick = nil
        commandIsDown = false
        guard !liveActions.isEmpty || !watches.isEmpty else { return }
        liveActions.removeAll()
        for pid in Array(watches.keys) { endWatch(pid) }
        log.info("Dropped pending checks: \(reason, privacy: .public)")
    }

    private func dropWorkForRemovedApps() {
        for (pid, action) in liveActions where !isAllowed(action.app.bundleID) {
            liveActions[pid] = nil
            endWatch(pid)
        }
        if let click = pendingClick, !isAllowed(click.app.bundleID) { pendingClick = nil }
    }

    private func frontmostChanged(to pid: pid_t) {
        frontmostPID = pid
        updateFocusTracking()
    }

    private func processEnded(_ pid: pid_t) {
        liveActions[pid] = nil
        endWatch(pid)
        focus.forget(pid)
        if pendingClick?.app.pid == pid { pendingClick = nil }
    }

    private func updateFocusTracking() {
        if monitoring, config.commandW, let app = allowedApp(frontmostPID) {
            focus.track(app.pid)
        } else {
            focus.track(nil)
        }
    }

    // MARK: - Events (Engine.queue)

    private func handle(_ event: TapEvent) {
        guard monitoring, config.enabled else { return }
        switch event {
        case let .mouseDown(location, flags, target):
            mouseDown(at: location, flags: flags, target: target)
        case let .mouseUp(location):
            mouseUp(at: location)
        case let .commandW(target, isRepeat):
            commandW(target: target, isRepeat: isRepeat)
        case .commandDown:
            commandIsDown = true
            commandDownAt = Engine.now
            if config.commandW { focus.commandPressed() }
        case .commandUp:
            commandIsDown = false
        case let .tapReenabled(reason):
            // Events were lost while the tap was off: a pending click or a ⌘ press might be stale.
            pendingClick = nil
            commandIsDown = false
            log.notice("Event tap was disabled (\(reason, privacy: .public)); re-enabled it")
        }
    }

    private func mouseDown(at location: CGPoint, flags: CGEventFlags, target: pid_t) {
        clickNumber &+= 1
        pendingClick = nil
        guard !ClickPolicy.ignoresMouseDown(flags: flags) else { return }
        // When the window server already says which process gets the click, apps that
        // aren't on the list aren't even hit-tested.
        if target > 0 && allowedApp(target) == nil { return }

        guard let button = AXKit.element(at: location).value,
              AXKit.string(button, kAXSubroleAttribute).value == kAXCloseButtonSubrole,
              let pid = AXKit.pid(of: button) else { return }
        guard target <= 0 || target == pid else {
            log.notice("Close button belongs to pid \(pid) but the click goes to pid \(target); ignoring")
            return
        }
        guard let app = allowedApp(pid) else { return }
        // A disabled close button (for example while a sheet is open) does nothing when clicked;
        // if its state can't be read, don't guess.
        switch AXKit.bool(button, kAXEnabledAttribute) {
        case .value(false), .gone, .failed: return
        case .value(true), .missing: break
        }
        // Only the close button of a real window counts, not a panel's or a palette's.
        guard let window = AXKit.element(button, kAXWindowAttribute).value,
              AXKit.pid(of: window) == pid,
              inspector.kind(of: window)?.isRealWindow == true,
              let frame = AXKit.frame(of: button).value else { return }
        pendingClick = PendingClick(number: clickNumber, app: app, button: button, buttonFrame: frame, window: window)
        log.info("Close button pressed in \(app.name, privacy: .public); waiting for the release")
    }

    private func mouseUp(at location: CGPoint) {
        guard let click = pendingClick, click.number == clickNumber else { return }
        pendingClick = nil
        guard ClickPolicy.releaseConfirmsClose(buttonFrame: click.buttonFrame, releaseLocation: location) else {
            log.info("Released outside \(click.app.name, privacy: .public)'s close button: cancelled")
            return
        }
        begin(click.app, source: .closeButton, closedWindow: click.window)
    }

    private func commandW(target: pid_t, isRepeat: Bool) {
        guard config.commandW, let app = allowedApp(frontmostPID) else { return }
        if target > 0 && target != app.pid {
            log.info("⌘W went to \(self.processName(target), privacy: .public), not \(app.name, privacy: .public); ignoring")
            return
        }
        if target <= 0 {
            // This event carries no target, so ask Accessibility who has keyboard focus.
            guard let focusedApp = AXKit.element(AXKit.systemWide, kAXFocusedApplicationAttribute).value,
                  AXKit.pid(of: focusedApp) == app.pid else {
                log.info("⌘W: keyboard focus isn't in \(app.name, privacy: .public); ignoring")
                return
            }
        }
        // Judge ⌘W by a snapshot taken after ⌘ went down, so a window that closed some other
        // way earlier can't make an app with no windows look like it had one.
        guard commandIsDown, let snapshot = focus.snapshot, snapshot.pid == app.pid,
              snapshot.takenAt >= commandDownAt else {
            if !isRepeat { report(.ignored, "Ignored ⌘W in \(app.name) — couldn't tell which windows were open.") }
            return
        }
        guard !snapshot.realWindows.isEmpty else {
            if !isRepeat { report(.ignored, "Ignored ⌘W in \(app.name) — it had no window open.") }
            return
        }
        begin(app, source: .commandW, closedWindow: snapshot.focusedRealWindow)
    }

    // MARK: - Deciding (Engine.queue)

    private func begin(_ app: AppIdentity, source: CloseSource, closedWindow: AXUIElement?) {
        lastActionID &+= 1
        let action = CloseAction(id: lastActionID, app: app, source: source, closedWindow: closedWindow, time: Engine.now)
        endWatch(app.pid)  // a new close replaces any earlier wait on this app
        liveActions[app.pid] = action
        log.info("\(source.label, privacy: .public) closed a window of \(app.name, privacy: .public); looking in \(Int(self.config.checkDelay * 1000)) ms")
        Engine.queue.asyncAfter(deadline: .now() + config.checkDelay) { [weak self] in
            self?.firstLook(action)
        }
    }

    /// Still the newest action for that app, still enabled, still allowed, still the same process?
    private func isLive(_ action: CloseAction) -> Bool {
        monitoring && config.enabled
            && liveActions[action.app.pid]?.id == action.id
            && isAllowed(action.app.bundleID)
            && action.app.isStillRunning
    }

    private func firstLook(_ action: CloseAction) {
        guard isLive(action) else { return }
        let look = inspector.inspect(pid: action.app.pid, closedWindow: action.closedWindow)
        log.info("\(action.app.name, privacy: .public), first look: \(look.census.summary, privacy: .public) → \(String(describing: look.verdict), privacy: .public)")
        perform(DecisionPolicy.afterFirstLook(look.verdict, closedWindowStillOpen: look.closedWindowStillOpen), action, look)
    }

    private func recheck(_ action: CloseAction, spacesAtFirstLook: Set<UInt64>?) {
        guard isLive(action) else { return }
        let look = inspector.inspect(pid: action.app.pid, closedWindow: action.closedWindow)
        log.info("\(action.app.name, privacy: .public), second look: \(look.census.summary, privacy: .public) → \(String(describing: look.verdict), privacy: .public)")
        perform(DecisionPolicy.afterRecheck(look.verdict, spacesUnchanged: look.visibleSpaces == spacesAtFirstLook),
                action, look)
    }

    private func perform(_ step: NextStep, _ action: CloseAction, _ look: Inspection) {
        switch step {
        case .recheck:
            let spaces = look.visibleSpaces
            Engine.queue.asyncAfter(deadline: .now() + DecisionPolicy.recheckDelay) { [weak self] in
                self?.recheck(action, spacesAtFirstLook: spaces)
            }
        case .quit:
            quit(action)
        case .watch(let dialog):
            startWatch(action, dialog: dialog, look: look)
        case .stop(let reason):
            finish(action, "Kept \(action.app.name) open — \(reason).")
        }
    }

    private func quit(_ action: CloseAction) {
        guard isLive(action) else { return }
        liveActions[action.app.pid] = nil
        endWatch(action.app.pid)
        let app = action.app
        let message = "Quit \(app.name) — you closed its last window (\(action.source.label))."
        log.notice("Quitting \(app.name, privacy: .public) (pid \(app.pid))")
        let reportOnMain = self.reportOnMain
        let latestConfig = self.latestConfig
        DispatchQueue.main.async {
            // Last checks right before the request: still on, still on the list, still the same
            // process. Then a normal quit (never forceTerminate), so the app can still ask to
            // save changes, or refuse.
            let config = latestConfig.withLock { $0 }
            guard config.enabled, config.allowlist.contains(app.bundleID), !Denylist.contains(app.bundleID),
                  app.isStillRunning, let running = NSRunningApplication(processIdentifier: app.pid) else { return }
            if running.terminate() {
                reportOnMain(.quit, message)
            } else {
                reportOnMain(.problem, "Couldn't ask \(app.name) to quit.")
            }
        }
    }

    private func finish(_ action: CloseAction, _ message: String) {
        let pid = action.app.pid
        if liveActions[pid]?.id == action.id { liveActions[pid] = nil }
        if watches[pid]?.action.id == action.id { endWatch(pid) }
        report(.kept, message)
    }

    // MARK: - Watching (Engine.queue)

    private func startWatch(_ action: CloseAction, dialog: Bool, look: Inspection) {
        let pid = action.app.pid
        endWatch(pid)
        let watch = Watch(action: action, state: WatchPolicy.start(actionTime: action.time, dialog: dialog))
        watches[pid] = watch

        watch.token = AXObserverCenter.shared.add(pid: pid) { [weak self, weak watch] _, _ in
            guard let self, let watch else { return }
            self.somethingChanged(in: watch)
        }
        if let token = watch.token {
            let appElement = AXKit.application(pid)
            // Hide-on-close apps order the window out instead of destroying it; focus changes catch that.
            for name in [kAXWindowCreatedNotification, kAXSheetCreatedNotification,
                         kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                AXObserverCenter.shared.register(token, name, on: appElement)
            }
        } else {
            log.notice("No AXObserver for \(action.app.name, privacy: .public); relying on the timed checks")
        }
        observeDestruction(of: look.watchTargets, in: watch)
        scheduleDeadlineCheck(for: watch)

        if dialog {
            report(.waiting, "\(action.app.name) is showing a dialog — waiting up to \(Int(DecisionPolicy.dialogWatchDuration)) s for its last window to close.")
        }
    }

    private func observeDestruction(of elements: [AXUIElement], in watch: Watch) {
        guard let token = watch.token else { return }
        for element in elements where !watch.observed.contains(where: { CFEqual($0, element) }) {
            let result = AXObserverCenter.shared.register(token, kAXUIElementDestroyedNotification, on: element)
            if result == .success || result == .notificationAlreadyRegistered {
                watch.observed.append(element)
            }
        }
    }

    private func somethingChanged(in watch: Watch) {
        guard watches[watch.action.app.pid] === watch, !watch.changePending else { return }
        watch.changePending = true
        // Let a burst of notifications settle (a sheet closing, then its window), then look once.
        Engine.queue.asyncAfter(deadline: .now() + 0.15) { [weak self, weak watch] in
            guard let self, let watch else { return }
            watch.changePending = false
            self.evaluate(watch)
        }
    }

    private func scheduleCheck(_ watch: Watch, at time: TimeInterval) {
        Engine.queue.asyncAfter(deadline: .now() + max(0, time - Engine.now)) { [weak self, weak watch] in
            guard let self, let watch else { return }
            self.evaluate(watch)
        }
    }

    private func scheduleDeadlineCheck(for watch: Watch) {
        guard watch.state.deadline > watch.deadlineScheduled else { return }
        watch.deadlineScheduled = watch.state.deadline
        scheduleCheck(watch, at: watch.state.deadline)
    }

    private func evaluate(_ watch: Watch, isRecheck: Bool = false) {
        let action = watch.action
        guard watches[action.app.pid] === watch else { return }
        guard isLive(action) else {
            endWatch(action.app.pid)
            return
        }
        if watch.recheckPending && !isRecheck { return }  // a confirming look is already on its way

        let look = inspector.inspect(pid: action.app.pid, closedWindow: action.closedWindow)
        let now = Engine.now
        let step = isRecheck
            ? WatchPolicy.afterRecheck(look.verdict, closedWindowStillOpen: look.closedWindowStillOpen,
                                       spacesUnchanged: look.visibleSpaces == watch.recheckSpaces,
                                       state: &watch.state, now: now)
            : WatchPolicy.evaluate(look.verdict, closedWindowStillOpen: look.closedWindowStillOpen, state: &watch.state, now: now)
        log.info("Watching \(action.app.name, privacy: .public): \(look.census.summary, privacy: .public) → \(String(describing: step), privacy: .public)")

        switch step {
        case .quit:
            quit(action)
        case .recheck:
            watch.recheckPending = true
            watch.recheckSpaces = look.visibleSpaces
            Engine.queue.asyncAfter(deadline: .now() + DecisionPolicy.recheckDelay) { [weak self, weak watch] in
                guard let self, let watch else { return }
                watch.recheckPending = false
                self.evaluate(watch, isRecheck: true)
            }
        case .keepWatching(let lookAgainAt):
            observeDestruction(of: look.watchTargets, in: watch)
            scheduleDeadlineCheck(for: watch)
            if let lookAgainAt, watch.graceCheckScheduled != lookAgainAt {
                watch.graceCheckScheduled = lookAgainAt
                scheduleCheck(watch, at: lookAgainAt)
            }
        case .stop(let reason):
            finish(action, "Kept \(action.app.name) open — \(reason).")
        }
    }

    private func endWatch(_ pid: pid_t) {
        guard let watch = watches.removeValue(forKey: pid) else { return }
        if let token = watch.token { AXObserverCenter.shared.remove(token) }
    }

    // MARK: - Helpers (Engine.queue)

    private func allowedApp(_ pid: pid_t) -> AppIdentity? {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
              let bundleID = running.bundleIdentifier, isAllowed(bundleID) else { return nil }
        return AppIdentity(pid: pid, bundleID: bundleID, name: running.localizedName ?? bundleID, launchDate: running.launchDate)
    }

    private func isAllowed(_ bundleID: String) -> Bool {
        config.allowlist.contains(bundleID) && !Denylist.contains(bundleID)
    }

    private func processName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)"
    }

    private func report(_ kind: ActivityKind, _ message: String) {
        log.info("\(message, privacy: .public)")
        let reportOnMain = self.reportOnMain
        DispatchQueue.main.async { reportOnMain(kind, message) }
    }
}
