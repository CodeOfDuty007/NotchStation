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

    /// Records what a real attempt achieved. Failures back off for 3 minutes so the duck can't
    /// peck the same page over and over; successes and stale targets only pause briefly.
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
        var failedKeys = Set<String>()   // tabs the duck could not close: never re-targeted
    }

/// Identity used to remember a tab that failed to close. Chromium tabs have a stable id, so a
    /// new tab never inherits another's failure and a moved tab is still recognised; Safari tabs
    /// have none, so position + address is the best available.
    private static func tabKey(_ t: DoomTab) -> String {
        t.tabID != 0 ? "id:\(t.browser.bundleID):\(t.windowID):\(t.tabID)" : "pos:\(t.browser.bundleID):\(t.windowID):\(t.index):\(t.url)"
    }

    /// All tabs covered by a spent rule - foreground and background, every window of every running
    /// supported browser - ordered so the trigger tab goes first and, within a window, right to left
    /// (closing from the right keeps the remaining tabs' indices valid).
    private func planSweep(trigger: DoomTab?, exclude: Set<String> = []) async -> [DoomTab] {
        let spent = Defaults[.antiDoomRules].filter { $0.kind == .url && $0.isExhausted }
        var found: [DoomTab] = []
        for browser in DoomBrowser.supported where browser.isRunning {
            switch await BrowserBridge.allTabs(browser) {
            case .success(let tabs):
                deniedBrowsers.remove(browser.bundleID)
                found += tabs.filter { tab in
                    !exclude.contains(Self.tabKey(tab)) && spent.contains { $0.matches(url: tab.url) }
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
            /// The window is re-read for every stop (tabs reflow as others close), its true frame is
            /// taken from the window server, and the active tab's cross is re-measured from a screenshot.
            func nextStop() async -> DuckTrip? {
                while sweep.next < sweep.plan.count {
                    let tab = sweep.plan[sweep.next]
                    sweep.next += 1
                    let winKey = "\(tab.browser.bundleID):\(tab.windowID)"
                    let target = Target.tab(tab)
                    guard Self.stillEnforceable(target) else { continue }
                    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: tab.browser.bundleID).first?.processIdentifier ?? 0

                    var count = sweep.counts[winKey] ?? tab.count
                    var bounds = tab.bounds
                    var activeIndex: Int?
                    var title = ""
                    if let live = await BrowserBridge.windowState(tab) { count = live.count; bounds = live.bounds; activeIndex = live.activeIndex; title = live.title }
                    bounds = Self.trueBounds(pid: pid, like: bounds, title: title)
                    guard Defaults[.antiDoomEnabled] else { return nil }

                    let r = DuckGeometry.cocoaRect(fromQuartz: bounds, primaryHeight: primaryHeight)
                    guard let screen = DuckGeometry.screen(for: r) else { continue }
                    let fullScreen = DuckGeometry.isFullScreen(windowCocoa: r, screen: screen.frame)
                    var anchor: (index: Int, closeX: CGFloat)?
                    if !fullScreen, !tab.browser.isSafari, let active = activeIndex {
                        let guess = DuckGeometry.tabTarget(windowCocoa: r, isSafari: false, index: active, count: count).x - r.minX
                        if let snap = await DoomShot.snapshot(pid: pid, quartzBounds: bounds),
                           let x = DoomTabProbe.activeCloseX(snap, estimated: guess) { anchor = (active, x) }
                    }
                    let point = DuckGeometry.tabTarget(windowCocoa: r, isSafari: tab.browser.isSafari, index: tab.index,
                                                       count: count, anchor: anchor, fullScreen: fullScreen)
                    DoomShot.log("trip \(tab.browser.name) win=\(tab.windowID) tab=\(tab.index)/\(count) scriptBounds=\(tab.bounds) trueBounds=\(bounds) fullScreen=\(fullScreen) measured=\(anchor != nil) target=\(point)")
                    return DuckTrip(target: point, facingLeft: false, screenFrame: screen.frame) {
                        guard Self.stillEnforceable(target) else { return false }
                        // Each tab is shot on its own: its window just before the close, and again after.
                        let before = await DoomShot.capture(pid: pid, quartzBounds: bounds, label: "before")
                        let result = await BrowserBridge.close(tab)
                        try? await Task.sleep(for: .milliseconds(450))
                        let after = await DoomShot.capture(pid: pid, quartzBounds: bounds, label: "after")
                        DoomShot.log("close \(tab.browser.name) win=\(tab.windowID) tab=\(tab.index)/\(count) url=\(tab.url) -> \(result.detail) before=\(before?.lastPathComponent ?? "-") after=\(after?.lastPathComponent ?? "-")")
                        // "gate:" = never dispatched (interrupted); "gone:" = target changed (stale).
                        if !result.detail.hasPrefix("gate:") { sweep.attempted = true }
                        if !result.closed, !result.detail.hasPrefix("gate:"), !result.detail.hasPrefix("gone:") { sweep.failed = true }
                        if !result.closed { sweep.failedKeys.insert(Self.tabKey(tab)) }
                        if result.closed { sweep.counts[winKey] = count - 1 }
                        return result.closed
                    }
                }
                return nil
            }

            /// The next planned tab; once the plan is used up, rescan so tabs opened while the duck
            /// was working (or walking home) are picked up immediately.
            func nextOrRescan() async -> DuckTrip? {
                if let stop = await nextStop() { return stop }
                guard Defaults[.antiDoomEnabled] else { return nil }
                let fresh = await planSweep(trigger: nil, exclude: sweep.failedKeys)
                guard !fresh.isEmpty, Defaults[.antiDoomEnabled] else { return nil }
                sweep.plan = fresh; sweep.next = 0; sweep.counts = [:]
                return await nextStop()
            }

            guard Defaults[.antiDoomEnabled], let first = await nextStop() else { return }
            await DuckController.shared.run(first, next: { await nextOrRescan() })
            if sweep.attempted { noteOutcome(e.key, closed: !sweep.failed, failed: sweep.failed) }

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

    /// A browser's scripted window bounds can be wrong at the top edge (seen with a display arranged
    /// above the primary one: the top was reported 122pt too low), so the real frame is taken from
    /// the window server, matching on left edge, bottom edge and width, which stay correct.
    private static func trueBounds(pid: pid_t, like b: CGRect, title: String) -> CGRect {
        guard pid != 0, let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return b }
        var candidates: [(rect: CGRect, name: String)] = []
        for w in info {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let d = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: d["X"] ?? 0, y: d["Y"] ?? 0, width: d["Width"] ?? 0, height: d["Height"] ?? 0)
            if abs(r.minX - b.minX) <= 3, abs(r.maxY - b.maxY) <= 3, abs(r.width - b.width) <= 3 {
                candidates.append((r, (w[kCGWindowName as String] as? String) ?? ""))
            }
        }
        // Stacked windows can share left/bottom/width. The window's title identifies it: narrow the
        // matches to those whose window-server name matches the scripted title, then (only if that
        // still leaves several) take the one whose top and height are closest to the reported ones.
        var pool = candidates
        if !title.isEmpty {
            let named = candidates.filter { !$0.name.isEmpty && ($0.name == title || $0.name.hasPrefix(title) || title.hasPrefix($0.name)) }
            if !named.isEmpty { pool = named }
        }
        guard let best = pool.min(by: { abs($0.rect.minY - b.minY) + abs($0.rect.height - b.height) < abs($1.rect.minY - b.minY) + abs($1.rect.height - b.height) }) else { return b }
        if pool.count > 1 { DoomShot.log("trueBounds ambiguous: \(pool.count) windows match \(b) title=\(title); using \(best.rect)") }
        return best.rect
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
