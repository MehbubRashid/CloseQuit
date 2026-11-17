//
//  PrivateAPI.swift
//  CloseQuit
//
//  Undocumented but long-stable macOS functions, the same ones window managers and app
//  switchers use. They're looked up at runtime: if one ever disappears, the check that
//  needs it reports "unknown", which the engine treats as "don't quit".
//
//  Why they're needed: AXWindows only lists windows on the Spaces you can currently see.
//  A window on another desktop or in full screen would otherwise look like "no windows
//  left", and quitting then would close a window the user never touched.
//

import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum PrivateAPI {
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64

    /// kCGSAllSpacesMask: current, other and user Spaces.
    private static let allSpacesMask: Int32 = 0x7

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func lookup<T>(_ names: [String], as type: T.Type) -> T? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        for name in names {
            if let symbol = dlsym(defaultHandle, name) ?? skyLight.flatMap({ dlsym($0, name) }) {
                return unsafeBitCast(symbol, to: type)
            }
        }
        return nil
    }

    private static let axGetWindow = lookup(["_AXUIElementGetWindow"], as: AXGetWindowFn.self)
    private static let mainConnection = lookup(["CGSMainConnectionID", "SLSMainConnectionID"], as: ConnectionFn.self)
    private static let copySpacesForWindows = lookup(["CGSCopySpacesForWindows", "SLSCopySpacesForWindows"],
                                                     as: CopySpacesForWindowsFn.self)
    private static let copyManagedDisplaySpaces = lookup(["CGSCopyManagedDisplaySpaces", "SLSCopyManagedDisplaySpaces"],
                                                         as: CopyManagedDisplaySpacesFn.self)
    private static let getActiveSpace = lookup(["CGSGetActiveSpace", "SLSGetActiveSpace"], as: GetActiveSpaceFn.self)

    private static let connection: Int32? = mainConnection?()

    /// Whether Accessibility windows can be matched to window-server windows.
    static var canMapWindows: Bool { axGetWindow != nil }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow else { return nil }
        var id: CGWindowID = 0
        return axGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// The Spaces a window is assigned to; empty if none (never shown, or closed).
    /// `nil` when it can't be determined.
    static func spaces(forWindow id: CGWindowID) -> [UInt64]? {
        guard let copySpacesForWindows, let connection else { return nil }
        let ids = [NSNumber(value: id)] as CFArray
        guard let array = copySpacesForWindows(connection, allSpacesMask, ids)?.takeRetainedValue() as? [NSNumber] else {
            return nil
        }
        return array.map(\.uint64Value)
    }

    /// The Space currently shown on each display (including full-screen Spaces).
    static func visibleSpaceIDs() -> Set<UInt64>? {
        guard let connection else { return nil }
        if let copyManagedDisplaySpaces,
           let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] {
            var ids = Set<UInt64>()
            for display in displays {
                guard let current = display["Current Space"] as? [String: Any],
                      let id = (current["id64"] ?? current["ManagedSpaceID"]) as? NSNumber else { continue }
                ids.insert(id.uint64Value)
            }
            if !ids.isEmpty { return ids }
        }
        if let getActiveSpace {
            let id = getActiveSpace(connection)
            if id != 0 { return [id] }
        }
        return nil
    }
}
