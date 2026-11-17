//
//  AppModel.swift
//  CloseQuit
//
//  UI state and settings. Owns the CloseMonitor and pushes every change to it.
//

import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct AllowedApp: Codable, Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    var name: String
    var path: String?
}

struct AddableApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let url: URL?
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let kind: ActivityKind
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    private enum Keys {
        static let enabled = "enabled"
        static let commandW = "commandW"
        static let checkDelayMs = "checkDelayMs"
        static let apps = "apps"
    }

    static let checkDelayRange = 200...2000

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            applyConfig()
        }
    }

    @Published var commandWEnabled: Bool {
        didSet {
            defaults.set(commandWEnabled, forKey: Keys.commandW)
            applyConfig()
        }
    }

    @Published var checkDelayMs: Int {
        didSet {
            let clamped = min(max(checkDelayMs, Self.checkDelayRange.lowerBound), Self.checkDelayRange.upperBound)
            if clamped != checkDelayMs { checkDelayMs = clamped }
            defaults.set(checkDelayMs, forKey: Keys.checkDelayMs)
            applyConfig()
        }
    }

    @Published private(set) var apps: [AllowedApp] {
        didSet {
            saveApps()
            applyConfig()
            refreshAddableApps()
        }
    }

    @Published private(set) var addableApps: [AddableApp] = []
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var status: MonitorStatus = .paused
    @Published private(set) var launchAtLoginEnabled: Bool

    private let defaults = UserDefaults.standard
    private var monitor: CloseMonitor?
    private var trustTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var iconCache: [String: NSImage] = [:]

    init() {
        defaults.register(defaults: [Keys.enabled: true, Keys.commandW: true, Keys.checkDelayMs: 400])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        commandWEnabled = defaults.bool(forKey: Keys.commandW)
        checkDelayMs = min(max(defaults.integer(forKey: Keys.checkDelayMs), Self.checkDelayRange.lowerBound),
                           Self.checkDelayRange.upperBound)
        apps = Self.loadApps(from: defaults)
        accessibilityGranted = AXIsProcessTrusted()
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        monitor = CloseMonitor { [weak self] kind, message in
            MainActor.assumeIsolated { self?.record(kind, message) }
        }
        watchAccessibilityTrust()
        watchRunningApps()
        refreshAddableApps()
        applyConfig()
    }

    // MARK: - Status

    var menuBarSymbol: String {
        switch status {
        case .running: return "xmark.circle"
        case .paused: return "pause.circle"
        case .needsAccessibility, .failed: return "exclamationmark.circle"
        }
    }

    var statusLine: String {
        switch status {
        case .running:
            switch apps.count {
            case 0: return "On — add an app to start"
            case 1: return "On — watching 1 app"
            default: return "On — watching \(apps.count) apps"
            }
        case .paused: return "Paused"
        case .needsAccessibility: return "Needs Accessibility access"
        case .failed: return "Couldn't start"
        }
    }

    // MARK: - Apps

    func add(_ app: AddableApp) {
        add(bundleID: app.bundleID, name: app.name, path: app.url?.path)
    }

    func remove(_ app: AllowedApp) {
        apps.removeAll { $0.bundleID == app.bundleID }
    }

    func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = "Add Apps to CloseQuit"
        panel.message = "Choose apps that should quit when you close their last window."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                for url in urls { self?.addApplication(at: url) }
            }
        }
    }

    private func addApplication(at url: URL) {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            record(.problem, "Couldn't add \(url.lastPathComponent): it has no bundle identifier.")
            return
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        add(bundleID: bundleID, name: name, path: url.path)
    }

    private func add(bundleID: String, name: String, path: String?) {
        guard !Denylist.contains(bundleID) else {
            record(.problem, "CloseQuit never quits \(name).")
            return
        }
        guard !apps.contains(where: { $0.bundleID == bundleID }) else { return }
        var updated = apps
        updated.append(AllowedApp(bundleID: bundleID, name: name, path: path))
        updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        apps = updated
    }

    func icon(for app: AllowedApp) -> NSImage {
        icon(bundleID: app.bundleID, path: app.path)
    }

    /// A 16 pt copy for menu items, which otherwise show icons at full size.
    func menuIcon(for app: AddableApp) -> NSImage {
        let image = (icon(bundleID: app.bundleID, path: app.url?.path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func icon(bundleID: String, path: String?) -> NSImage {
        if let cached = iconCache[bundleID] { return cached }
        let url = path.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
        iconCache[bundleID] = image
        return image
    }

    func refreshAddableApps() {
        let added = Set(apps.map(\.bundleID))
        var seen = Set<String>()
        addableApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AddableApp? in
                guard let id = app.bundleIdentifier, !added.contains(id), !Denylist.contains(id),
                      seen.insert(id).inserted else { return nil }
                return AddableApp(bundleID: id, name: app.localizedName ?? id, url: app.bundleURL)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func watchRunningApps() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAddableApps() }
            })
        }
    }

    private static func loadApps(from defaults: UserDefaults) -> [AllowedApp] {
        guard let data = defaults.data(forKey: Keys.apps),
              let apps = try? JSONDecoder().decode([AllowedApp].self, from: data) else { return [] }
        return apps
    }

    private func saveApps() {
        if let data = try? JSONEncoder().encode(apps) { defaults.set(data, forKey: Keys.apps) }
    }

    // MARK: - Accessibility permission

    func requestAccessibility() {
        // Prompting also adds CloseQuit to the list in System Settings, switched off.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startTrustTimer()
    }

    private func watchAccessibilityTrust() {
        // Posted whenever an app's Accessibility access changes; the trust check lags it slightly.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.refreshAccessibilityTrust() }
            }
        })
        if !accessibilityGranted { startTrustTimer() }
    }

    /// Only runs while access is missing (it checks the permission, not windows) and stops once granted.
    private func startTrustTimer() {
        guard trustTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibilityTrust() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    func refreshAccessibilityTrust() {
        let granted = AXIsProcessTrusted()
        if granted {
            trustTimer?.invalidate()
            trustTimer = nil
        } else {
            startTrustTimer()
        }
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        applyConfig()
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            record(.problem, "Couldn't change Launch at Login: \(error.localizedDescription)")
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Engine

    func menuDidOpen() {
        refreshAccessibilityTrust()
        refreshAddableApps()
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func applyConfig() {
        guard let monitor else { return }
        let config = EngineConfig(enabled: isEnabled,
                                  commandW: commandWEnabled,
                                  checkDelay: Double(checkDelayMs) / 1000,
                                  allowlist: Set(apps.map(\.bundleID)))
        monitor.update(config, accessibilityGranted: accessibilityGranted) { [weak self] status in
            MainActor.assumeIsolated { self?.status = status }
        }
    }

    private func record(_ kind: ActivityKind, _ message: String) {
        activity.insert(ActivityEntry(kind: kind, message: message), at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }
}
