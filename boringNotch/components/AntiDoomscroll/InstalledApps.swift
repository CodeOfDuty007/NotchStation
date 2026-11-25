//
//  InstalledApps.swift
//  boringNotch
//

import AppKit

struct InstalledApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
}

/// Apps installed on this Mac (plus anything currently running), for the app-rule picker.
enum InstalledApps {
    static func load() async -> [InstalledApp] {
        await Task.detached(priority: .utility) { scan() }.value
    }

    private static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications",
                     NSHomeDirectory() + "/Applications"]
        var found: [String: InstalledApp] = [:]
        for root in roots {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                        options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                if e.level > 3 { e.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                let info = bundle.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                found[id] = InstalledApp(bundleID: id, name: name)
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, found[id] == nil {
                found[id] = InstalledApp(bundleID: id, name: app.localizedName ?? id)
            }
        }
        found.removeValue(forKey: Bundle.main.bundleIdentifier ?? "")
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
