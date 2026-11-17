//
//  AXObserverCenter.swift
//  CloseQuit
//
//  Owns every AXObserver. Callbacks arrive on the engine's run-loop thread, carry only an
//  integer token, and are looked up on the engine queue, so a callback that arrives after
//  an observer was removed is simply dropped (no dangling pointers).
//

import ApplicationServices
import Foundation

final class AXObserverCenter {
    static let shared = AXObserverCenter()

    typealias Handler = (_ notification: String, _ element: AXUIElement) -> Void

    private struct Entry {
        let observer: AXObserver
        let source: CFRunLoopSource
        let handler: Handler
    }

    // Engine.queue only.
    private var entries: [Int: Entry] = [:]
    private var nextToken = 1

    private init() {}

    /// Creates an observer for `pid`. The handler runs on the engine queue. Engine.queue only.
    func add(pid: pid_t, handler: @escaping Handler) -> Int? {
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let observer = created else {
            return nil
        }
        let source = AXObserverGetRunLoopSource(observer)
        let runLoop = Engine.thread.runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
        let token = nextToken
        nextToken += 1
        entries[token] = Entry(observer: observer, source: source, handler: handler)
        return token
    }

    /// Engine.queue only.
    @discardableResult
    func register(_ token: Int, _ notification: String, on element: AXUIElement) -> AXError {
        guard let entry = entries[token] else { return .invalidUIElementObserver }
        return AXObserverAddNotification(entry.observer, element, notification as CFString,
                                         UnsafeMutableRawPointer(bitPattern: token))
    }

    /// Engine.queue only.
    func remove(_ token: Int) {
        guard let entry = entries.removeValue(forKey: token) else { return }
        let runLoop = Engine.thread.runLoop
        // Detach and release the observer on its own run-loop thread, between callbacks, so
        // it can never be freed while one of its callbacks is running.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            CFRunLoopRemoveSource(runLoop, entry.source, .commonModes)
            withExtendedLifetime(entry) {}
        }
        CFRunLoopWakeUp(runLoop)
    }

    fileprivate func deliver(token: Int, notification: String, element: AXUIElement) {
        Engine.queue.async {
            self.entries[token]?.handler(notification, element)
        }
    }
}

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    AXObserverCenter.shared.deliver(token: Int(bitPattern: refcon), notification: notification as String, element: element)
}
