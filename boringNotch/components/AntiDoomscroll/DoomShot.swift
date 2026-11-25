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

    /// Captures just this browser window (not the whole screen), so each tab is shot on its own.
    @discardableResult
    static func capture(pid: pid_t, quartzBounds: CGRect, label: String) async -> URL? {
        guard CGPreflightScreenCaptureAccess() else {
            log("screenshot \(label) skipped: Screen Recording permission not granted")
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            guard let window = candidates.min(by: { distance($0.frame, quartzBounds) < distance($1.frame, quartzBounds) }) else {
                log("screenshot \(label) skipped: window not found"); return nil
            }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            let url = directory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(label).png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, nil)
            return CGImageDestinationFinalize(dest) ? url : nil
        } catch {
            log("screenshot \(label) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
