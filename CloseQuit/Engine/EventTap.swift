//
//  EventTap.swift
//  CloseQuit
//
//  A listen-only CGEventTap. It never changes or delays events: the callback copies a few
//  fields and hands them to the engine queue, where all Accessibility work happens.
//

import CoreGraphics
import Foundation

enum TapEvent {
    case mouseDown(location: CGPoint, flags: CGEventFlags, targetPID: pid_t)
    case mouseUp(location: CGPoint)
    case commandW(targetPID: pid_t, isRepeat: Bool)
    /// ⌘ went down: take the "windows before ⌘W" snapshot.
    case commandDown
    case commandUp
    /// macOS switched the tap off and we switched it back on; events may have been missed.
    case tapReenabled(reason: String)
}

final class EventTap {
    private let sink: (TapEvent) -> Void
    // Only touched on the run-loop thread (install/uninstall run there via RunLoopThread.sync).
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var commandHeld = false

    /// `sink` is called on the tap's thread and must return quickly.
    init(sink: @escaping (TapEvent) -> Void) {
        self.sink = sink
    }

    /// Call on the run-loop thread. Returns false if macOS refuses to create the tap
    /// (no Accessibility permission).
    func install(on runLoop: CFRunLoop) -> Bool {
        if port != nil { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .keyDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // The annotated session tap sees events after the window server has decided which
        // process receives them, so every event carries its target PID: a free cross-check
        // against the app we think the user is acting on. Tail placement means we see what
        // the app actually gets, after any remapping tools.
        let created = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: eventTapCallback, userInfo: refcon)
            ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                 options: .listenOnly, eventsOfInterest: mask,
                                 callback: eventTapCallback, userInfo: refcon)
        guard let created else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        port = created
        self.source = source
        commandHeld = false
        return true
    }

    /// Call on the run-loop thread.
    func uninstall(from runLoop: CFRunLoop) {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        self.source = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switched the tap off; switch it straight back on. Modifier changes may
            // have been missed meanwhile, so forget what we knew about ⌘.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            commandHeld = false
            sink(.tapReenabled(reason: type == .tapDisabledByTimeout ? "timeout" : "user input"))
        case .leftMouseDown:
            sink(.mouseDown(location: event.location, flags: event.flags, targetPID: targetPID(of: event)))
        case .leftMouseUp:
            sink(.mouseUp(location: event.location))
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // Cheap integer test first; only a ⌘ + key-13 press pays for reading its text.
            guard ShortcutMatcher.isCommandWChord(keyCode: keyCode, flags: event.flags),
                  ShortcutMatcher.isPlainCommandW(keyCode: keyCode, flags: event.flags, characters: typedText(of: event))
            else { return }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            sink(.commandW(targetPID: targetPID(of: event), isRepeat: isRepeat))
        case .flagsChanged:
            let held = event.flags.contains(.maskCommand)
            guard held != commandHeld else { return }
            commandHeld = held
            sink(held ? .commandDown : .commandUp)
        default:
            break
        }
    }

    private func targetPID(of event: CGEvent) -> pid_t {
        pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
    }

    /// The text the key types in the current keyboard layout, as recorded in the event.
    private func typedText(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: min(max(length, 0), buffer.count))
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
