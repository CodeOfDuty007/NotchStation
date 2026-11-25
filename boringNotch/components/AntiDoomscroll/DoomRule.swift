//
//  DoomRule.swift
//  boringNotch
//

import Defaults
import Foundation

/// One anti-doomscroll limit: a website (base URL like `instagram.com`, or a URL with a path
/// like `reddit.com/r/all`) or an installed app, plus a time allowance.
///
/// `usedSeconds` is persisted and deliberately NOT reset when the tab/app closes. The allowance
/// is renewed 12 hours after the rule was first used in the current window (`windowStart`).
struct DoomRule: Codable, Identifiable, Equatable, Defaults.Serializable {
    enum Kind: String, Codable { case url, app }

    /// Allowance renewal period, measured from the first use in a window.
    static let renewalInterval: TimeInterval = 12 * 3600
    static let minLimitSeconds = 60
    static let maxLimitSeconds = 24 * 3600

    var id = UUID()
    var kind: Kind
    /// `.url`: normalized host without `www.` (e.g. `instagram.com`).
    var host: String = ""
    /// `.url`: lowercase path prefix without trailing slash; empty means the whole site.
    var pathPrefix: String = ""
    /// `.app`: bundle identifier.
    var bundleID: String = ""
    var title: String
    var limitSeconds: Int
    var usedSeconds: Double = 0
    var windowStart: Date?

    var isExhausted: Bool { usedSeconds >= Double(limitSeconds) }
    var resetDate: Date? { windowStart?.addingTimeInterval(Self.renewalInterval) }
    var remainingSeconds: Double { max(0, Double(limitSeconds) - usedSeconds) }

    var subtitle: String {
        switch kind {
        case .url: return pathPrefix.isEmpty ? host : host + pathPrefix
        case .app: return bundleID
        }
    }

    /// Stable identity of the target, so usage survives delete + re-add within a window.
    var ledgerKey: String {
        switch kind {
        case .url: return "url:" + host + pathPrefix
        case .app: return "app:" + bundleID
        }
    }

    static func clampLimit(_ seconds: Int) -> Int {
        min(max(seconds, minLimitSeconds), maxLimitSeconds)
    }

    static func website(_ input: String, limitSeconds: Int) -> DoomRule? {
        guard let parsed = DoomURL.parse(input) else { return nil }
        let title = parsed.path.isEmpty ? parsed.host : parsed.host + parsed.path
        return DoomRule(kind: .url, host: parsed.host, pathPrefix: parsed.path, title: title,
                        limitSeconds: clampLimit(limitSeconds))
    }

    static func app(bundleID: String, name: String, limitSeconds: Int) -> DoomRule {
        DoomRule(kind: .app, bundleID: bundleID, title: name, limitSeconds: clampLimit(limitSeconds))
    }

    /// Does this rule cover `url` (a tab's address)? Apps never match URLs.
    func matches(url: String) -> Bool {
        guard kind == .url, let tab = DoomURL.parse(url) else { return false }
        guard tab.host == host || tab.host.hasSuffix("." + host) else { return false }
        if pathPrefix.isEmpty { return true }
        return tab.path == pathPrefix || tab.path.hasPrefix(pathPrefix + "/")
    }

    func matches(bundleID id: String) -> Bool {
        kind == .app && !bundleID.isEmpty && bundleID == id
    }
}

/// Pure URL normalization shared by rule creation and tab matching.
enum DoomURL {
    static func parse(_ input: String) -> (host: String, path: String)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let comps = URLComponents(string: text), ["http", "https"].contains(comps.scheme ?? ""),
              var host = comps.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host == "localhost" || (host.contains(".") && !host.hasPrefix(".") && !host.contains("..")) else { return nil }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        return (host, path)
    }
}

/// Usage remembered for a removed rule so deleting and re-adding it can't reset the allowance.
struct DoomLedgerEntry: Codable, Equatable, Defaults.Serializable {
    var usedSeconds: Double
    var windowStart: Date
}
