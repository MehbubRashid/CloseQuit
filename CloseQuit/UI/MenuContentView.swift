//
//  MenuContentView.swift
//  CloseQuit
//

import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(model: model)
            if model.status == .needsAccessibility {
                PermissionCard(model: model)
            } else if case .failed(let message) = model.status {
                NoticeCard(symbol: "exclamationmark.triangle.fill", title: "CloseQuit couldn't start", message: message)
            }
            SectionDivider()
            AppsSection(model: model)
            SectionDivider()
            OptionsSection(model: model)
            SectionDivider()
            ActivitySection(entries: model.activity)
            SectionDivider()
            FooterView()
        }
        .frame(width: 320)
        .onAppear { model.menuDidOpen() }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("CloseQuit").font(.headline)
                Text(model.statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: $model.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(model.isEnabled ? "Pause CloseQuit" : "Turn CloseQuit on")
        }
        .padding(12)
    }
}

private struct PermissionCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Accessibility access needed", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
            Text("CloseQuit uses it to see which window you closed. Until you allow it, CloseQuit does nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings…") { model.requestAccessibility() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding([.horizontal, .bottom], 12)
    }
}

private struct NoticeCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.callout.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding([.horizontal, .bottom], 12)
    }
}

// MARK: - Apps

private struct AppsSection: View {
    @ObservedObject var model: AppModel
    private let maxVisibleRows = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionTitle("Apps")
                Spacer()
                AddAppButton(model: model)
            }
            if model.apps.isEmpty {
                Text("Add an app with +. CloseQuit only ever quits apps on this list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else if model.apps.count > maxVisibleRows {
                ScrollView { rows }
                    .frame(height: CGFloat(maxVisibleRows) * 28)
            } else {
                rows
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(model.apps) { app in
                AppRow(app: app, model: model)
            }
        }
    }
}

private struct AddAppButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            if model.addableApps.isEmpty {
                Text("No other apps are open")
            } else {
                Section("Open Apps") {
                    ForEach(model.addableApps) { app in
                        Button {
                            model.add(app)
                        } label: {
                            Label {
                                Text(app.name)
                            } icon: {
                                Image(nsImage: model.menuIcon(for: app))
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Choose from Applications…") {
                DispatchQueue.main.async { model.chooseApplications() }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add an app")
    }
}

private struct AppRow: View {
    let app: AllowedApp
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: model.icon(for: app))
                .resizable()
                .frame(width: 20, height: 20)
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                model.remove(app)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(hovering ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove \(app.name)")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
    }
}

// MARK: - Options

private struct OptionsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(title: "Also react to ⌘W", detail: "Quit when ⌘W closes the last window.") {
                Toggle("Also react to ⌘W", isOn: $model.commandWEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            SettingRow(title: "Check after", detail: "How long to wait after a close before looking.") {
                HStack(spacing: 2) {
                    Text("\(model.checkDelayMs) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("Check after", value: $model.checkDelayMs, in: AppModel.checkDelayRange, step: 50)
                        .labelsHidden()
                }
            }
            SettingRow(title: "Launch at login") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLoginEnabled },
                                                        set: { model.setLaunchAtLogin($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

// MARK: - Activity

private struct ActivitySection: View {
    let entries: [ActivityEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Recent")
            if entries.isEmpty {
                Text("Nothing yet. Close a window in one of your apps and CloseQuit's decision shows up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(entries.prefix(6)) { entry in
                    ActivityRow(entry: entry)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(entry.kind.tint)
                .font(.caption)
            Text(entry.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(entry.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private extension ActivityKind {
    var symbol: String {
        switch self {
        case .quit: return "xmark.circle.fill"
        case .kept: return "checkmark.circle"
        case .waiting: return "hourglass"
        case .ignored: return "minus.circle"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .quit: return .red
        case .kept: return .secondary
        case .waiting: return .orange
        case .ignored: return .secondary
        case .problem: return .orange
        }
    }
}

// MARK: - Footer and shared bits

private struct FooterView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        HStack {
            Text("CloseQuit \(version)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit CloseQuit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct SectionDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 12)
    }
}
