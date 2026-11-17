//
//  AXKit.swift
//  CloseQuit
//
//  Thin wrapper over the Accessibility C API that keeps the difference between "this
//  attribute isn't there" and "we couldn't find out" (timeout, app not responding).
//  The engine treats the second kind as a reason to do nothing.
//

import ApplicationServices
import CoreGraphics

enum AXRead<T> {
    case value(T)
    /// The attribute is unsupported or has no value.
    case missing
    /// The element no longer exists.
    case gone
    /// Timed out, Accessibility disabled, or another error: the answer is unknown.
    case failed(AXError)

    var value: T? {
        if case .value(let value) = self { return value }
        return nil
    }

    /// The value, `nil` if the attribute isn't there, or a thrown `AXFailure` when unknown.
    func get() throws -> T? {
        switch self {
        case .value(let value): return value
        case .missing: return nil
        case .gone: throw AXFailure.gone
        case .failed(let error): throw AXFailure.failed(error)
        }
    }

    func cast<U>(_ transform: (T) -> U?) -> AXRead<U> {
        switch self {
        case .value(let value): return transform(value).map(AXRead<U>.value) ?? .missing
        case .missing: return .missing
        case .gone: return .gone
        case .failed(let error): return .failed(error)
        }
    }
}

enum AXFailure: Error {
    case gone
    case failed(AXError)

    var label: String {
        switch self {
        case .gone: return "it went away"
        case .failed(let error): return error.label
        }
    }
}

extension AXError {
    var label: String {
        switch self {
        case .cannotComplete: return "the app didn't answer in time"
        case .apiDisabled: return "Accessibility access is off"
        case .notImplemented: return "the app doesn't support it"
        case .invalidUIElement: return "it went away"
        default: return "AX error \(rawValue)"
        }
    }
}

enum AXKit {
    /// Every Accessibility call gives up after this long, so a hung app can't stall us.
    static let messagingTimeout: Float = 0.5

    /// Setting the timeout on the system-wide element makes it the default for every
    /// Accessibility call this process makes.
    static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }()

    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> AXRead<CFTypeRef> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return read(error, value)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> AXRead<String> {
        copy(element, attribute).cast { $0 as? String }
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> AXRead<Bool> {
        copy(element, attribute).cast { $0 as? Bool }
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXRead<AXUIElement> {
        copy(element, attribute).cast(asElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> AXRead<[AXUIElement]> {
        copy(element, attribute).cast { value in
            (value as? [AnyObject])?.compactMap(asElement)
        }
    }

    static func size(of element: AXUIElement) -> AXRead<CGSize> {
        copy(element, kAXSizeAttribute).cast(unpackSize)
    }

    static func frame(of element: AXUIElement) -> AXRead<CGRect> {
        let origin = copy(element, kAXPositionAttribute).cast(unpackPoint)
        guard case .value(let point) = origin else { return origin.cast { _ in nil } }
        let size = size(of: element)
        guard case .value(let extent) = size else { return size.cast { _ in nil } }
        return .value(CGRect(origin: point, size: extent))
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }

    /// Hit test in global screen coordinates (top-left origin, same as CGEvent locations).
    static func element(at point: CGPoint) -> AXRead<AXUIElement> {
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
        return read(error, element)
    }

    private static func read<T>(_ error: AXError, _ value: T?) -> AXRead<T> {
        switch error {
        case .success: return value.map(AXRead.value) ?? .missing
        case .noValue, .attributeUnsupported: return .missing
        case .invalidUIElement: return .gone
        default: return .failed(error)
        }
    }

    private static func asElement(_ value: AnyObject) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
    }

    private static func axValue(_ value: CFTypeRef, of type: AXValueType) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    private static func unpackPoint(_ value: CFTypeRef) -> CGPoint? {
        guard let axValue = axValue(value, of: .cgPoint) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func unpackSize(_ value: CFTypeRef) -> CGSize? {
        guard let axValue = axValue(value, of: .cgSize) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}
