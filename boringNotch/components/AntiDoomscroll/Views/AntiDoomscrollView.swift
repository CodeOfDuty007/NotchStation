//
//  AntiDoomscrollView.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

/// Notch tab for the anti-doomscroll duck: the master slider (the only off switch), the list of
/// websites/apps with their allowances, and an editor to add more.
struct AntiDoomscrollView: View {
    @Default(.antiDoomEnabled) private var enabled
    @Default(.antiDoomRules) private var rules
    @StateObject private var manager = AntiDoomscrollManager.shared
    @State private var adding = false

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                header
                if !enabled {
                    note("The duck is asleep. Switch it on to start counting time on your listed sites and apps.")
                }
                if enabled, !manager.deniedBrowsers.isEmpty {
                    note("Allow Automation for \(manager.deniedBrowsers.compactMap { DoomBrowser.with(bundleID: $0)?.name }.joined(separator: ", ")) in System Settings > Privacy & Security > Automation, or the duck can't see its tabs.")
                        .foregroundStyle(.orange)
                }
                list
            }
            .disabled(adding)
            .opacity(adding ? 0.25 : 1)

            if adding {
                DoomRuleEditor(onAdd: { rule in
                    // One rule per target: a duplicate would start with a fresh allowance.
                    if !rules.contains(where: { $0.ledgerKey == rule.ledgerKey }) {
                        rules.append(AntiDoomscrollManager.restoringUsage(rule))
                    }
                    adding = false
                }, onCancel: { adding = false })
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: adding)
    }

    private var header: some View {
        HStack(spacing: 8) {
            DuckIcon()
            Text("Anti-Doomscroll")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { adding = true } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color(nsColor: .secondarySystemFill)))
            }
            .buttonStyle(.plain)
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(enabled ? "Switch off to stop the duck reading tabs and closing them" : "Wake the duck")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var list: some View {
        if rules.isEmpty {
            Spacer()
            Text("Add a website (instagram.com) or an app with a time limit.")
                .font(.system(size: 11)).foregroundStyle(.gray)
            Spacer()
        } else {
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(rules) { rule in
                        DoomRuleRow(rule: rule) {
                            AntiDoomscrollManager.rememberUsage(rule)
                            rules.removeAll { $0.id == rule.id }
                        }
                    }
                }
            }
        }
    }
}

private struct DoomRuleRow: View {
    let rule: DoomRule
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(status)
                    .font(.system(size: 9)).monospacedDigit()
                    .foregroundStyle(rule.isExhausted ? Color.red : Color.gray)
            }
            Spacer(minLength: 6)
            ProgressView(value: min(1, rule.usedSeconds / Double(rule.limitSeconds)))
                .tint(rule.isExhausted ? .red : Color.effectiveAccent)
                .frame(width: 90)
            Text("\(PomodoroTimeFormat.display(rule.usedSeconds)) / \(PomodoroTimeFormat.display(Double(rule.limitSeconds)))")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .frame(width: 92, alignment: .trailing)
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
            .help("Remove from list")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    private var status: String {
        if rule.isExhausted, let reset = rule.resetDate {
            return "Limit reached - renews \(reset.formatted(date: .omitted, time: .shortened))"
        }
        return rule.kind == .app ? "App" : rule.subtitle
    }

    @ViewBuilder private var icon: some View {
        if rule.kind == .app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: rule.kind == .app ? "app" : "globe").foregroundStyle(.gray)
        }
    }
}

/// Add-a-rule form. The notch window can't normally take keystrokes, so (like the Pomodoro time
/// editor) it asks to become key and holds the notch open while it is on screen.
struct DoomRuleEditor: View {
    enum Mode: String, CaseIterable { case website = "Website", app = "App" }

    let onAdd: (DoomRule) -> Void
    let onCancel: () -> Void

    @State private var mode: Mode = .website
    @State private var urlText = ""
    @State private var minutesText = "30"
    @State private var apps: [InstalledApp] = []
    @State private var selectedApp = ""
    @State private var hostWindow: NSWindow?
    @State private var holding = false
    @State private var previousApp: NSRunningApplication?
    @FocusState private var urlFocused: Bool

    private var limitSeconds: Int? {
        guard let m = Int(minutesText.trimmingCharacters(in: .whitespaces)), m >= 1, m <= 24 * 60 else { return nil }
        return m * 60
    }
    private var builtRule: DoomRule? {
        guard let limit = limitSeconds else { return nil }
        switch mode {
        case .website: return DoomRule.website(urlText, limitSeconds: limit)
        case .app:
            guard let app = apps.first(where: { $0.bundleID == selectedApp }) else { return nil }
            return DoomRule.app(bundleID: app.bundleID, name: app.name, limitSeconds: limit)
        }
    }
    private var firefoxWarning: Bool { DoomBrowser.unsupportedBundleIDs.contains(selectedApp) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 160)

            HStack(spacing: 8) {
                if mode == .website {
                    TextField("instagram.com or reddit.com/r/all", text: $urlText)
                        .focused($urlFocused)
                        .onSubmit(commit)
                } else {
                    Picker("", selection: $selectedApp) {
                        Text("Choose an app...").tag("")
                        ForEach(apps) { Text($0.name).tag($0.bundleID) }
                    }
                    .labelsHidden()
                }
                TextField("min", text: $minutesText)
                    .frame(width: 44).multilineTextAlignment(.trailing)
                    .onSubmit(commit)
                Text("min").font(.system(size: 11)).foregroundStyle(.gray)
            }
            .textFieldStyle(.roundedBorder)

            if firefoxWarning {
                Text("Firefox can't expose its tabs, so this limits the whole app.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.plain).foregroundStyle(.gray)
                Button(action: commit) {
                    Text("Add").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 4)
                        .background(Capsule().fill(builtRule == nil ? Color.gray.opacity(0.4) : Color.effectiveAccent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain).disabled(builtRule == nil)
            }
        }
        .font(.system(size: 11))
        .padding(14)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.effectiveAccent.opacity(0.6), lineWidth: 1))
        .background(PomodoroWindowReader { hostWindow = $0 })
        .task { apps = await InstalledApps.load() }
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let closing = note.object as? NSWindow, closing === hostWindow { end() }
        }
        .onExitCommand(perform: onCancel)
    }

    private func commit() {
        guard let rule = builtRule else { return }
        onAdd(rule)
    }

    private func begin() {
        guard !holding else { return }
        holding = true
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front?.processIdentifier == ProcessInfo.processInfo.processIdentifier) ? nil : front
        SharingStateManager.shared.beginInteraction()
        BoringNotchSkyLightWindow.textEntryHolders += 1
        DispatchQueue.main.async {
            hostWindow?.makeKey()
            urlFocused = true
        }
    }

    private func end() {
        guard holding else { return }
        holding = false
        BoringNotchSkyLightWindow.textEntryHolders = max(0, BoringNotchSkyLightWindow.textEntryHolders - 1)
        if let window = hostWindow, window.isKeyWindow { previousApp?.activate() }
        previousApp = nil
        SharingStateManager.shared.endInteraction()
    }
}
