//
//  DoomShot.swift
//  boringNotch
//

import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Before/after screenshots of the window the duck is about to act on, plus a plain-text log of
/// every attempt, kept in Application Support/DoomLog. Screenshots need the Screen Recording
/// permission; without it they are skipped (the log still records why).
enum DoomShot {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DoomLog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func log(_ line: String) {
        let url = directory.appendingPathComponent("log.txt")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Asks for Screen Recording up front (when the switch is turned on), so the system prompt
    /// never steals focus from the browser in the middle of a trip.
    static func requestAccessIfNeeded() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    /// A captured window plus its pixels-per-point scale.
    struct Snapshot: @unchecked Sendable {
        let image: CGImage
        let scale: CGFloat
    }

    /// Captures just this browser window (not the whole screen). Never blocks for long: window
    /// capture can hang or fail (e.g. full-screen windows on another Space), and the close must not
    /// wait on it, so it gives up after `timeout` seconds.
    static func snapshot(pid: pid_t, quartzBounds: CGRect, timeout: Double = 1.5) async -> Snapshot? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        return await withTimeout(timeout) { await rawSnapshot(pid: pid, quartzBounds: quartzBounds) }
    }

    /// Snapshot saved as a PNG (before/after evidence).
    @discardableResult
    static func capture(pid: pid_t, quartzBounds: CGRect, label: String) async -> URL? {
        guard CGPreflightScreenCaptureAccess() else {
            log("screenshot \(label) skipped: Screen Recording permission not granted")
            return nil
        }
        guard let snap = await snapshot(pid: pid, quartzBounds: quartzBounds) else {
            log("screenshot \(label) skipped: capture failed or timed out")
            return nil
        }
        let url = directory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(label).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, snap.image, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    private static func rawSnapshot(pid: pid_t, quartzBounds: CGRect) async -> Snapshot? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            guard let window = candidates.min(by: { distance($0.frame, quartzBounds) < distance($1.frame, quartzBounds) }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Snapshot(image: image, scale: scale)
        } catch {
            log("screenshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Runs `op`, returning nil if it hasn't finished after `seconds` (the op is abandoned, not awaited).
    private static func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T?) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = Once<T?>(cont)
            Task { once.resume(await op()) }
            Task { try? await Task.sleep(for: .seconds(seconds)); once.resume(nil) }
        }
    }

    private final class Once<V>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<V, Never>?
        init(_ c: CheckedContinuation<V, Never>) { cont = c }
        func resume(_ value: V) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: value)
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

/// Finds where the active tab really ends by looking at a captured window, so the duck can aim at
/// the real close button instead of an estimate.
enum DoomTabProbe {
    /// X of the active tab's close button, in points from the window's left edge, or nil when the
    /// tab can't be located confidently. Works for Chromium-style tab strips: the active tab is the
    /// only tab filled with a different colour from the strip, so a row just below the tab's top
    /// edge (above the title text) is scanned for the extent of that fill.
    static func activeCloseX(_ snap: DoomShot.Snapshot, estimated: CGFloat) -> CGFloat? {
        let sc = snap.scale
        let row = Int(10 * sc)
        let img = snap.image
        guard row < img.height - 1, let band = img.cropping(to: CGRect(x: 0, y: row, width: img.width, height: 1)) else { return nil }
        let w = band.width
        var px = [UInt8](repeating: 0, count: w * 4)
        guard let ctx = CGContext(data: &px, width: w, height: 1, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(band, in: CGRect(x: 0, y: 0, width: w, height: 1))

        func color(_ x: Int) -> (Int, Int, Int) { (Int(px[x * 4]), Int(px[x * 4 + 1]), Int(px[x * 4 + 2])) }
        func same(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
            abs(a.0 - b.0) <= 14 && abs(a.1 - b.1) <= 14 && abs(a.2 - b.2) <= 14
        }
        let seed = Int((estimated - 60) * sc)
        guard seed > 0, seed < w - 1 else { return nil }
        let fill = color(seed)

        var last = seed, gap = 0, x = seed + 1
        while x < w {
            if same(color(x), fill) { last = x; gap = 0 } else { gap += 1; if gap > Int(3 * sc) { break } }
            x += 1
        }
        let right = CGFloat(last) / sc
        // Sanity: the tab's right edge must be near where a close button is expected.
        guard right > estimated - 40, right < estimated + 60 else { return nil }
        return right - 16
    }
}
