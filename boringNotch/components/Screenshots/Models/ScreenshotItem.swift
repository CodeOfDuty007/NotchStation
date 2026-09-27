//
//  ScreenshotItem.swift
//  boringNotch
//

import Foundation

/// A single screenshot found in the watched folder, identified by its file path so
/// re-scans can tell "still the same file" apart from "a new file landed here".
struct ScreenshotItem: Identifiable, Equatable, Hashable {
    let url: URL
    let captureDate: Date
    let fileSizeBytes: Int
    /// Inode of the file at the time it was scanned, used right before trashing it to make
    /// sure we're not deleting a different file that has since replaced it at the same path.
    let fileIdentifier: UInt64?

    var id: String { url.path }

    var displayName: String { url.deletingPathExtension().lastPathComponent }

    var fileSizeKB: Int {
        max(1, Int((Double(fileSizeBytes) / 1024).rounded()))
    }

    static func == (lhs: ScreenshotItem, rhs: ScreenshotItem) -> Bool {
        lhs.url == rhs.url && lhs.captureDate == rhs.captureDate && lhs.fileSizeBytes == rhs.fileSizeBytes
    }
}
