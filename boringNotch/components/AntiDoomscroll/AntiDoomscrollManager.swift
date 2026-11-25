//
//  AntiDoomscrollManager.swift
//  boringNotch
//

import AppKit
import Combine
import CoreGraphics
import Defaults
import SwiftUI

/// Always-running guard behind the Anti-Doomscroll tab. It lives for the whole app session (not
/// the tab's view) so time keeps being counted while the notch is closed.
///
/// Counting: a rule accrues time only while it is the active tab of the front window of the
/// frontmost browser (or the frontmost app, for app rules). Time persists when the tab closes and
/// renews 12 hours after the first use. When a rule's allowance is spent, a duck is sent to close
/// the offending tab (or quit the app). The master switch is the only off switch: when it is off
/// nothing is read and nothing is closed.
@MainActor
final class AntiDoomscrollManager: ObservableObject {
    static let shared = AntiDoomscrollManager()

    private enum Target {
        case tab(DoomTab)
        case app(pid: pid_t, bundleID: String, window: CGRect?)
    }
    private struct Enforcement { let key: String; let target: Target }

    /// Browsers the user has denied Automation access to (shown as a warning in the tab).
    @Published private(set) var deniedBrowsers: Set<String> = []

    private let pollInterval: TimeInterval = 2
    private let maxDelta: TimeInterval = 5          // a sleep/wake gap must not dump hours of usage
    private var timer: Timer?
    private var lastTick: Date?
    private var ticking = false
    /// What the previous tick saw in the foreground; time accrues only across ticks that saw the same thing.
    private var lastObservation: String?
    private var queue: [Enforcement] = []
    private var draining = false
    private var cooldown: [String: Date] = [:]
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Defaults.publisher(.antiDoomEnabled).sink { [weak self] change in
            if change.newValue { DoomShot.requestAccessIfNeeded(); return }
            Task { @MainActor in self?.shutDown() }
        }.store(in: &cancellables)
    }

    /// Slider turned off: forget in-flight work and send the duck home.
    private func shutDown() {
        queue.removeAll()
        lastTick = nil
        lastObservation = nil
        DuckController.shared.abort()
    }

    // MARK: Tick

    private func tick() async {
        guard Defaults[.antiDoomEnabled] else { lastTick = nil; lastObservation = nil; return }
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }

        let now = Date()
        let dt = lastTick.map { min(max(now.timeIntervalSince($0), 0), maxDelta) } ?? 0
        lastTick = now
        renewExpiredWindows(now)

        let rules = Defaults[.antiDoomRules]
        // Any tick that can't observe a qualifying foreground breaks the chain of observations,
        // so time away from the target is never charged when it returns.
        guard !rules.isEmpty, CGDisplayIsAsleep(CGMainDisplayID()) == 0,
              let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else {
            lastObservation = nil
            return
        }

        var frontTab: DoomTab?
        if let browser = DoomBrowser.with(bundleID: bundleID), rules.contains(where: { $0.kind == .url }) {
            switch await BrowserBridge.frontTab(browser) {
            case .success(let tab): frontTab = tab; deniedBrowsers.remove(bundleID)
            case .failure(.denied): deniedBrowsers.insert(bundleID)
            case .failure(.failed): break
            }
        }
        // The slider may have been switched off, or the user may have switched apps, while the
        // script ran; in either case this observation no longer describes the foreground.
        guard Defaults[.antiDoomEnabled],
              NSWorkspace.shared.frontmostApplication?.processIdentifier == front.processIdentifier else { return }

        var matched: [UUID] = []
        for rule in rules {
            if rule.kind == .app, rule.matches(bundleID: bundleID) { matched.append(rule.id) }
            if rule.kind == .url, let tab = frontTab, rule.matches(url: tab.url) { matched.append(rule.id) }
        }
        let observation = "\(bundleID)|" + (frontTab.map { "\($0.windowID):\($0.index)" } ?? "") + "|"
            + matched.map(\.uuidString).sorted().joined(separator: ",")
        let sameAsBefore = observation == lastObservation
        lastObservation = observation
        if !matched.isEmpty { accrue(matched, dt: sameAsBefore ? dt : 0, now: now) }

        let updated = Defaults[.antiDoomRules]
        for rule in updated where rule.isExhausted && matched.contains(rule.id) {
            if rule.kind == .url, let tab = frontTab {
                if isBackedOff(tab) { continue }
                enqueue(Enforcement(key: "tabs", target: .tab(tab)))
            } else if rule.kind == .app {
                enqueue(Enforcement(key: "app:\(bundleID)",
                                    target: .app(pid: front.processIdentifier, bundleID: bundleID,
                                                 window: Self.largestWindow(of: front.processIdentifier))))
            }
        }

    }

    // MARK: Accounting

    /// Removing a rule remembers its usage; re-adding the same target within the 12h window
    /// picks it back up, so delete + re-add is not a reset.
    static func rememberUsage(_ rule: DoomRule) {
        guard let start = rule.windowStart, rule.usedSeconds > 0 else { return }
        Defaults[.antiDoomLedger][rule.ledgerKey] = DoomLedgerEntry(usedSeconds: rule.usedSeconds, windowStart: start)
    }

    static func restoringUsage(_ rule: DoomRule) -> DoomRule {
        var rule = rule
        let entry = Defaults[.antiDoomLedger][rule.ledgerKey]
        Defaults[.antiDoomLedger].removeValue(forKey: rule.ledgerKey)
        if let entry, Date() < entry.windowStart.addingTimeInterval(DoomRule.renewalInterval) {
            rule.usedSeconds = entry.usedSeconds
            rule.windowStart = entry.windowStart
        }
        return rule
    }

    private func renewExpiredWindows(_ now: Date) {
        var rules = Defaults[.antiDoomRules]
        var changed = false
        for i in rules.indices {
            if let reset = rules[i].resetDate, now >= reset {
                rules[i].usedSeconds = 0
                rules[i].windowStart = nil
                changed = true
            }
        }
        if changed { Defaults[.antiDoomRules] = rules }
    }

    private func accrue(_ ids: [UUID], dt: TimeInterval, now: Date) {
        var rules = Defaults[.antiDoomRules]
        for i in rules.indices where ids.contains(rules[i].id) {
            if rules[i].windowStart == nil { rules[i].windowStart = now }
            rules[i].usedSeconds = min(rules[i].usedSeconds + dt, Double(rules[i].limitSeconds) + 1)
        }
        Defaults[.antiDoomRules] = rules
    }

    // MARK: Enforcement

    private func enqueue(_ e: Enforcement) {
        guard Defaults[.antiDoomEnabled], !queue.contains(where: { $0.key == e.key }) else { return }
        if let until = cooldown[e.key], until > Date() { return }
        queue.append(e)
        drain()
    }

    /// One duck, one trip at a time.
    private func drain() {
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            while Defaults[.antiDoomEnabled], !queue.isEmpty {
                let e = queue.removeFirst()
                await perform(e)
            }
            queue.removeAll()
            draining = false
        }
    }

    /// A trip may only act while a spent rule still covers its target; deleting the rule (or
    /// the slider going off) mid-trip cancels the close/quit.
    private static func stillEnforceable(_ target: Target) -> Bool {
        guard Defaults[.antiDoomEnabled] else { return false }
        let rules = Defaults[.antiDoomRules]
        switch target {
        case .tab(let tab): return rules.contains { $0.kind == .url && $0.isExhausted && $0.matches(url: tab.url) }
        case .app(_, let bundleID, _): return rules.contains { $0.kind == .app && $0.isExhausted && $0.matches(bundleID: bundleID) }
        }
    }

    private var outcomeRecorded = Set<String>()
    /// Failure memory. Chromium tabs have a stable id, so only that exact tab is backed off for
    /// 3 minutes. Safari tabs have no id, so a position-based key could hit a different tab;
    /// instead three failures in a row pause that browser for 3 minutes.
    private var failedTabUntil: [String: Date] = [:]
    private var browserFailures: [String: Int] = [:]
    private var browserBlockedUntil: [String: Date] = [:]

    private func isBackedOff(_ t: DoomTab) -> Bool {
        let now = Date()
        if t.tabID != 0 {
            return failedTabUntil["\(t.browser.bundleID):\(t.windowID):\(t.tabID)"].map { $0 > now } ?? false
        }
        return browserBlockedUntil[t.browser.bundleID].map { $0 > now } ?? false
    }

    private func recordFailure(_ t: DoomTab) {
        let until = Date().addingTimeInterval(180)
        if t.tabID != 0 {
            failedTabUntil["\(t.browser.bundleID):\(t.windowID):\(t.tabID)"] = until
        } else {
            let n = (browserFailures[t.browser.bundleID] ?? 0) + 1
            if n >= 3 { browserBlockedUntil[t.browser.bundleID] = until; browserFailures[t.browser.bundleID] = 0 }
            else { browserFailures[t.browser.bundleID] = n }
        }
    }

    private func recordSuccess(_ t: DoomTab) {
        if t.tabID == 0 { browserFailures[t.browser.bundleID] = 0 }
    }

    /// Records what a real attempt achieved for an enforcement key: a failed app quit backs off
    /// for 3 minutes so the duck can't hound the same app; successes and stale targets only
    /// pause briefly. (Failed tab closes are tracked per tab by `recordFailure`.)
    private func noteOutcome(_ key: String, closed: Bool, failed: Bool) {
        outcomeRecorded.insert(key)
        cooldown[key] = Date().addingTimeInterval(closed ? 2 : (failed ? 180 : 3))
    }

    /// Mutable bookkeeping for one multi-tab outing (a class so the duck's closures can share it).
    private final class Sweep {
        var plan: [DoomTab] = []
        var next = 0
        var counts: [String: Int] = [:]   // live tab count per window as tabs are closed
        var attempted = false
        var failed = false
    }

    private static func tabKey(_ t: DoomTab) -> String { "\(t.browser.bundleID):\(t.windowID):\(t.index):\(t.url)" }

    /// All tabs covered by a spent rule - foreground and background, every window of every running
    /// supported browser - ordered so the trigger tab goes first and, within a window, right to left
    /// (closing from the right keeps the remaining tabs' indices valid).
    private func planSweep(trigger: DoomTab?) async -> [DoomTab] {
        let spent = Defaults[.antiDoomRules].filter { $0.kind == .url && $0.isExhausted }
        var found: [DoomTab] = []
        for browser in DoomBrowser.supported where browser.isRunning {
            switch await BrowserBridge.allTabs(browser) {
            case .success(let tabs):
                deniedBrowsers.remove(browser.bundleID)
                found += tabs.filter { tab in
                    !isBackedOff(tab) && spent.contains { $0.matches(url: tab.url) }
                }
            case .failure(.denied): deniedBrowsers.insert(browser.bundleID)
            case .failure(.failed): break
            }
        }
        if let trigger, !found.contains(where: { $0.browser == trigger.browser && $0.windowID == trigger.windowID && $0.index == trigger.index }) {
            found.append(trigger)
        }
        return found.sorted {
            func rank(_ t: DoomTab) -> (Int, Int, Int, Int) {
                (t.browser == trigger?.browser ? 0 : 1, t.windowID == trigger?.windowID ? 0 : 1, t.windowID, -t.index)
            }
            return rank($0) < rank($1)
        }
    }

    private func perform(_ e: Enforcement) async {
        guard Self.stillEnforceable(e.target) else { return }
        // While the outing is in flight, don't re-queue the same target. The real outcome replaces
        // this: failed close = long back-off, success = brief pause, interrupted/stale = brief pause.
        cooldown[e.key] = Date().addingTimeInterval(30)
        defer {
            // No real attempt happened (trip interrupted or target invalid): only a brief pause.
            if outcomeRecorded.remove(e.key) == nil { cooldown[e.key] = Date().addingTimeInterval(3) }
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        switch e.target {
        case .tab(let trigger):
            let sweep = Sweep()
            sweep.plan = await planSweep(trigger: trigger)
            guard Defaults[.antiDoomEnabled] else { return }

            /// Builds the duck's next stop from the plan, skipping tabs whose rule is no longer spent.
            func nextStop() -> DuckTrip? {
                while sweep.next < sweep.plan.count {
                    let tab = sweep.plan[sweep.next]
                    sweep.next += 1
                    let winKey = "\(tab.browser.bundleID):\(tab.windowID)"
                    let count = sweep.counts[winKey] ?? tab.count
                    let target = Target.tab(tab)
                    guard Self.stillEnforceable(target) else { continue }
                    let r = DuckGeometry.cocoaRect(fromQuartz: tab.bounds, primaryHeight: primaryHeight)
                    guard let screen = DuckGeometry.screen(for: r) else { continue }
                    let point = DuckGeometry.tabTarget(windowCocoa: r, isSafari: tab.browser.isSafari, index: tab.index, count: count)
                    return DuckTrip(target: point, facingLeft: false, screenFrame: screen.frame) {
                        guard Self.stillEnforceable(target) else { return false }
                        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: tab.browser.bundleID).first?.processIdentifier ?? 0
                        // Each tab is shot on its own: its window just before the close, and again after.
                        let before = await DoomShot.capture(pid: pid, quartzBounds: tab.bounds, label: "before")
                        let result = await BrowserBridge.close(tab)
                        try? await Task.sleep(for: .milliseconds(450))
                        let after = await DoomShot.capture(pid: pid, quartzBounds: tab.bounds, label: "after")
                        DoomShot.log("close \(tab.browser.name) win=\(tab.windowID) tab=\(tab.index)/\(count) url=\(tab.url) -> \(result.detail) before=\(before?.lastPathComponent ?? "-") after=\(after?.lastPathComponent ?? "-")")
                        // "gate:" = never dispatched (interrupted); "gone:" = target changed (stale).
                        if !result.detail.hasPrefix("gate:") { sweep.attempted = true }
                        if !result.closed, !result.detail.hasPrefix("gate:"), !result.detail.hasPrefix("gone:") { sweep.failed = true }
                        if !result.closed, !result.detail.hasPrefix("gate:"), !result.detail.hasPrefix("gone:") {
                            self.recordFailure(tab)
                        }
                        if result.closed { self.recordSuccess(tab) }
                        if result.closed { sweep.counts[winKey] = count - 1 }
                        return result.closed
                    }
                }
                return nil
            }

            /// The next planned tab; once the plan is used up, rescan so tabs opened while the duck
            /// was working (or walking home) are picked up immediately.
            func nextOrRescan() async -> DuckTrip? {
                if let stop = nextStop() { return stop }
                guard Defaults[.antiDoomEnabled] else { return nil }
                let fresh = await planSweep(trigger: nil)
                guard !fresh.isEmpty, Defaults[.antiDoomEnabled] else { return nil }
                sweep.plan = fresh; sweep.next = 0; sweep.counts = [:]
                return nextStop()
            }

            guard Defaults[.antiDoomEnabled], let first = nextStop() else { return }
            await DuckController.shared.run(first, next: { await nextOrRescan() })
            if sweep.attempted { noteOutcome(e.key, closed: true, failed: false) }   // per-tab failures are remembered separately

        case .app(let pid, let bundleID, let window):
            // No qualifying window: fall back to the primary screen's top-left corner.
            let fallback = NSScreen.screens.first.map { CGRect(x: 0, y: 0, width: $0.frame.width, height: $0.frame.height) } ?? .zero
            let r = DuckGeometry.cocoaRect(fromQuartz: window ?? fallback, primaryHeight: primaryHeight)
            guard let screen = DuckGeometry.screen(for: r) else { return }
            let trip = DuckTrip(target: DuckGeometry.appTarget(windowCocoa: r), facingLeft: true, screenFrame: screen.frame) {
                guard Self.stillEnforceable(e.target), let app = NSRunningApplication(processIdentifier: pid),
                      app.bundleIdentifier == bundleID,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
                let quit = await Self.quit(app, stillEnforceable: { Self.stillEnforceable(e.target) })
                self.noteOutcome(e.key, closed: quit, failed: !quit)
                return quit
            }
            guard Defaults[.antiDoomEnabled] else { return }
            await DuckController.shared.run(trip)
        }
    }

    /// Asks the app to quit politely (never force-quits, so unsaved work gets its save prompt).
    /// If it is still running afterwards, hides it instead.
    private static func quit(_ app: NSRunningApplication, stillEnforceable: @MainActor () -> Bool) async -> Bool {
        _ = app.terminate()
        try? await Task.sleep(for: .seconds(2))
        if app.isTerminated { return true }
        // The rule may have been deleted (or the slider switched off) during the wait.
        guard stillEnforceable() else { return false }
        app.hide()
        return false
    }

    /// On-screen frame (Quartz coordinates) of the app's frontmost normal window.
    private static func largestWindow(of pid: pid_t) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return info.compactMap { w -> CGRect? in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return r.width > 100 && r.height > 100 ? r : nil
        }.first   // the list is ordered front to back: the app's frontmost normal window
    }
}
