//
//  Engine.swift
//  CloseQuit
//

import Foundation

/// Where the engine runs.
///
/// * The event tap and every AXObserver deliver callbacks on `thread`'s run loop. Those
///   callbacks only copy a few fields and hop to `queue`, so they return immediately.
/// * All engine state and every Accessibility call live on `queue` (serial), never on the
///   tap thread and never on the main thread.
enum Engine {
    static let queue = DispatchQueue(label: "CloseQuit.engine", qos: .userInitiated)

    static let thread: RunLoopThread = {
        let thread = RunLoopThread(name: "CloseQuit.events")
        thread.startAndWait()
        return thread
    }()

    /// Seconds since boot (excluding sleep), the same clock DispatchTime uses.
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// A background thread that runs a CFRunLoop forever.
final class RunLoopThread: Thread {
    private let started = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop?

    var runLoop: CFRunLoop {
        guard let loop else { preconditionFailure("RunLoopThread used before it started") }
        return loop
    }

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInteractive
    }

    func startAndWait() {
        start()
        started.wait()
    }

    override func main() {
        let loop = CFRunLoopGetCurrent()
        self.loop = loop
        // A run loop with nothing attached returns at once; this idle timer keeps it running.
        let keepAlive = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, Date.distantFuture.timeIntervalSinceReferenceDate, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, keepAlive, .commonModes)
        started.signal()
        while true { CFRunLoopRun() }
    }

    /// Runs `body` on this thread and waits for its result.
    func sync<T>(_ body: @escaping () -> T) -> T {
        if Thread.current === self { return body() }
        var result: T?
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            result = body()
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        return result!
    }
}
