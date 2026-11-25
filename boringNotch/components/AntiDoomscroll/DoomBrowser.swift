//
//  DoomBrowser.swift
//  boringNotch
//

import AppKit
import Defaults
import Foundation

struct DoomBrowser: Hashable {
    let bundleID: String
    let name: String
    /// Safari calls it the "current tab"; Chromium browsers call it the "active tab".
    let isSafari: Bool

    var activeTabExpression: String { isSafari ? "current tab" : "active tab" }
    /// AppleScript expression for the 1-based index of the active tab of window `w`.
    var activeIndexExpression: String { isSafari ? "index of current tab of w" : "active tab index of w" }

    /// Every browser whose tabs can be read/closed via AppleScript. Keep in sync with the
    /// `temporary-exception.apple-events` list in boringNotch.entitlements.
    static let supported: [DoomBrowser] = [
        .init(bundleID: "com.apple.Safari", name: "Safari", isSafari: true),
        .init(bundleID: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", isSafari: true),
        .init(bundleID: "com.google.Chrome", name: "Google Chrome", isSafari: false),
        .init(bundleID: "com.google.Chrome.canary", name: "Chrome Canary", isSafari: false),
        .init(bundleID: "org.chromium.Chromium", name: "Chromium", isSafari: false),
        .init(bundleID: "com.brave.Browser", name: "Brave", isSafari: false),
        .init(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", isSafari: false),
        .init(bundleID: "company.thebrowser.Browser", name: "Arc", isSafari: false),
        .init(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", isSafari: false),
        .init(bundleID: "com.operasoftware.Opera", name: "Opera", isSafari: false),
    ]

    /// Browsers with no tab scripting; only usable as whole-app rules.
    static let unsupportedBundleIDs: Set<String> = ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition"]

    static func with(bundleID: String) -> DoomBrowser? { supported.first { $0.bundleID == bundleID } }

    /// Running check used to gate every Apple Event: sending one to a closed app would launch it.
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
}

struct DoomTab: Equatable {
    let browser: DoomBrowser
    let windowID: Int
    let url: String
    /// 1-based index of the tab within its window (with window id + URL, identifies the tab).
    let index: Int
    /// Number of tabs in the window (used to estimate where the active tab sits).
    let count: Int
    /// Window frame in AppleScript/Quartz global coordinates (origin top-left of the primary display).
    let bounds: CGRect
}

enum BridgeError: Error { case denied, failed }

/// Reads and closes browser tabs through scripting. Every entry point refuses to run for a
/// browser that isn't already running.
enum BrowserBridge {
    static func frontTab(_ browser: DoomBrowser) async -> Result<DoomTab?, BridgeError> {
        guard Defaults[.antiDoomEnabled], browser.isRunning else { return .success(nil) }
        let script = """
        if application id "\(browser.bundleID)" is not running then return {}
        tell application id "\(browser.bundleID)"
            if (count of windows) is 0 then return {}
            set w to front window
            return {URL of \(browser.activeTabExpression) of w, bounds of w, id of w, \(browser.activeIndexExpression), count of tabs of w}
        end tell
        """
        do {
            guard let d = try await AppleScriptHelper.execute(script), d.numberOfItems == 5,
                  let url = d.atIndex(1)?.stringValue, !url.isEmpty,
                  let rect = rect(from: d.atIndex(2)), let wid = d.atIndex(3)?.int32Value,
                  let idx = d.atIndex(4)?.int32Value,
                  let cnt = d.atIndex(5)?.int32Value else { return .success(nil) }
            return .success(DoomTab(browser: browser, windowID: Int(wid), url: url, index: Int(idx), count: Int(cnt), bounds: rect))
        } catch { return .failure(classify(error)) }
    }

    /// Every tab in every window of a running browser (never launches it).
    static func allTabs(_ browser: DoomBrowser) async -> Result<[DoomTab], BridgeError> {
        guard Defaults[.antiDoomEnabled], browser.isRunning else { return .success([]) }
        let script = """
        set out to {}
        if application id "\(browser.bundleID)" is not running then return out
        tell application id "\(browser.bundleID)"
            repeat with w in windows
                set wid to id of w
                set b to bounds of w
                set cnt to count of tabs of w
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    set u to URL of t
                    if u is not missing value then set end of out to {wid, i, u, b, cnt}
                end repeat
            end repeat
        end tell
        return out
        """
        do {
            guard let d = try await AppleScriptHelper.execute(script) else { return .success([]) }
            var tabs: [DoomTab] = []
            for n in stride(from: 1, through: d.numberOfItems, by: 1) {
                guard let item = d.atIndex(n), item.numberOfItems == 5, let wid = item.atIndex(1)?.int32Value,
                      let idx = item.atIndex(2)?.int32Value, let url = item.atIndex(3)?.stringValue,
                      let r = rect(from: item.atIndex(4)), let cnt = item.atIndex(5)?.int32Value else { continue }
                tabs.append(DoomTab(browser: browser, windowID: Int(wid), url: url, index: Int(idx), count: Int(cnt), bounds: r))
            }
            return .success(tabs)
        } catch { return .failure(classify(error)) }
    }

    /// Live state of one window: its scripted bounds, tab count and active tab index.
    static func windowState(_ tab: DoomTab) async -> (bounds: CGRect, count: Int, activeIndex: Int, title: String)? {
        guard Defaults[.antiDoomEnabled], tab.browser.isRunning else { return nil }
        let script = """
        if application id "\(tab.browser.bundleID)" is not running then return {}
        tell application id "\(tab.browser.bundleID)"
            try
                set w to window id \(tab.windowID)
            on error
                return {}
            end try
            return {bounds of w, count of tabs of w, \(tab.browser.activeIndexExpression), \(tab.browser.isSafari ? "name" : "title") of w}
        end tell
        """
        guard let d = try? await AppleScriptHelper.execute(script), d.numberOfItems == 4,
              let r = rect(from: d.atIndex(1)), let n = d.atIndex(2)?.int32Value,
              let i = d.atIndex(3)?.int32Value else { return nil }
        return (r, Int(n), Int(i), d.atIndex(4)?.stringValue ?? "")
    }

    /// Closes one tab (foreground or background): the one at the observed index if it still has
    /// the observed address, otherwise the rightmost tab in that window with that address.
    /// Anything else is left alone.
    static func close(_ tab: DoomTab) async -> (closed: Bool, detail: String) {
        guard Defaults[.antiDoomEnabled], tab.browser.isRunning else { return (false, "gate: switch off or browser not running") }
        let script = """
        if application id "\(tab.browser.bundleID)" is not running then return "gone: not running"
        tell application id "\(tab.browser.bundleID)"
            try
                set w to window id \(tab.windowID)
            on error
                return "gone: window closed"
            end try
            set n to count of tabs of w
            set target to 0
            try
                if \(tab.index) <= n then
                    if (URL of tab \(tab.index) of w) is "\(escape(tab.url))" then set target to \(tab.index)
                end if
            end try
            if target is 0 then
                repeat with i from n to 1 by -1
                    try
                        if (URL of tab i of w) is "\(escape(tab.url))" then
                            set target to i
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            if target is 0 then return "gone: tab not found"
            close tab target of w
            return "ok"
        end tell
        """
        do {
            let result = try await AppleScriptHelper.execute(script)
            let text = result?.stringValue ?? "no result"
            return (text == "ok", text)
        } catch {
            let info = (error as NSError).userInfo
            return (false, "script error: \(info["NSAppleScriptErrorMessage"] ?? error.localizedDescription)")
        }
    }

    // MARK: Helpers

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func rect(from d: NSAppleEventDescriptor?) -> CGRect? {
        guard let d, d.numberOfItems == 4,
              let l = d.atIndex(1)?.int32Value, let t = d.atIndex(2)?.int32Value,
              let r = d.atIndex(3)?.int32Value, let b = d.atIndex(4)?.int32Value else { return nil }
        return CGRect(x: Int(l), y: Int(t), width: Int(r - l), height: Int(b - t))
    }

    /// -1743 = the user denied Automation access to that browser.
    private static func classify(_ error: Error) -> BridgeError {
        let info = (error as NSError).userInfo
        let code = (info["NSAppleScriptErrorNumber"] as? Int) ?? 0
        return code == -1743 ? .denied : .failed
    }
}
