//
//  ScreenshotStateViewModel.swift
//  boringNotch
//

import AppKit
import Darwin
import Defaults
import Foundation
import UniformTypeIdentifiers

/// Tracks the ten most recent screenshots in the folder the user grants access to
/// (their screen-capture save location, Desktop by default), lets the UI drag one out,
/// and moves the original to the Trash the moment that drag is dropped somewhere else.
///
/// Screenshots are never copied into the app - the list always mirrors what's really on
/// disk. Dragging a file out stages a disposable copy (see `stagedCopyURL(for:)`) so the
/// receiving app never races the delete; only the *original* gets trashed.
@MainActor
final class ScreenshotStateViewModel: ObservableObject {
    static let shared = ScreenshotStateViewModel()

    static let capacity = 10
    private static let pollInterval: TimeInterval = 1.5
    private static let screenCaptureXattr = "com.apple.metadata:kMDItemIsScreenCapture"
    private static let stagingDirectoryName = "BoringNotchScreenshotDrops"
    private static let stagedCopyMaxAge: TimeInterval = 60 * 60 * 24 // 1 day

    @Published private(set) var items: [ScreenshotItem] = []
    @Published private(set) var hasFolderAccess = false

    private var folderURL: URL?
    private var isAccessingFolderScope = false
    private var pollTimer: Timer?

    private init() {}

    var isEmpty: Bool { items.isEmpty }

    // MARK: - Folder access

    /// Resolves a previously-granted bookmark, if there is one. Safe to call more than once.
    func restoreAccessIfAvailable() {
        guard !hasFolderAccess else { return }
        guard let data = Defaults[.screenshotsFolderBookmark] else { return }
        let bookmark = Bookmark(data: data)
        let (url, refreshedData) = bookmark.resolve()
        if let refreshedData {
            Defaults[.screenshotsFolderBookmark] = refreshedData
        }
        guard let url else { return }
        beginAccessing(url)
    }

    /// Shows a folder picker (defaulting to the real ~/Desktop) so the user can grant
    /// persistent access to their screenshots folder. Returns whether access was granted.
    @discardableResult
    func requestFolderAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder your screenshots are saved to (Desktop, unless you've changed it)."
        panel.prompt = "Grant Access"
        panel.directoryURL = Self.realHomeDesktopURL()

        // The panel is presented from an AppKit event on a non-activating notch panel; make
        // sure we're actually frontmost or it can open behind whatever app was active.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosenURL = panel.url else { return false }

        guard let bookmark = try? Bookmark(url: chosenURL) else { return false }
        Defaults[.screenshotsFolderBookmark] = bookmark.data
        beginAccessing(chosenURL)
        return true
    }

    private func beginAccessing(_ url: URL) {
        stopAccessingFolderScope()
        guard url.startAccessingSecurityScopedResource() else { return }
        folderURL = url
        isAccessingFolderScope = true
        hasFolderAccess = true
        sweepStaleStagedCopies()
        scanFolder()
        startPolling()
    }

    /// Releases the held security scope. Call on app termination.
    func stopAccessingFolderScope() {
        pollTimer?.invalidate()
        pollTimer = nil
        if isAccessingFolderScope {
            folderURL?.stopAccessingSecurityScopedResource()
        }
        isAccessingFolderScope = false
        folderURL = nil
    }

    private static func realHomeDesktopURL() -> URL? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        let home = URL(fileURLWithPath: String(cString: dir))
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    // MARK: - Scanning

    private func startPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanFolder()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func scanFolder() {
        guard let folderURL else { return }

        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .contentTypeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        let scanned: [ScreenshotItem] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.contentType?.conforms(to: .image) == true,
                  isScreenCapture(url) else { return nil }

            let date = values.creationDate ?? values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0
            return ScreenshotItem(url: url, captureDate: date, fileSizeBytes: size, fileIdentifier: Self.inode(at: url.path))
        }

        let capped = Array(scanned.sorted { $0.captureDate > $1.captureDate }.prefix(Self.capacity))

        guard capped != items else { return }
        items = capped
        ScreenshotSelectionModel.shared.pruneSelection(toExisting: capped)
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        let size = url.path.withCString { path in
            getxattr(path, Self.screenCaptureXattr, nil, 0, 0, 0)
        }
        return size > 0
    }

    private static func inode(at path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    // MARK: - Consuming an item (drag-out -> trash)

    /// Writes a disposable copy of the screenshot's bytes to a scratch folder so the drop
    /// target can read it on its own schedule without racing the original being trashed.
    /// Written via `Data`, not `FileManager.copyItem`, so the copy does *not* carry the
    /// `kMDItemIsScreenCapture` xattr - otherwise dropping it back onto the watched folder
    /// would make it reappear in the tray.
    func stagedCopyURL(for item: ScreenshotItem) -> URL? {
        guard let data = try? Data(contentsOf: item.url) else { return nil }
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
        let dropDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = dropDir.appendingPathComponent(item.url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            NSLog("⚠️ ScreenshotStateViewModel: failed to stage copy for drag: \(error.localizedDescription)")
            return nil
        }
    }

    /// Moves the original screenshot to the Trash. Only called once a drag-out has actually
    /// completed (see `ScreenshotDragSource`) - never on click, selection, or preview.
    func trashOriginal(of item: ScreenshotItem) {
        // Guard against a "Replace" drop having put a different file at this path since we scanned it.
        if let expected = item.fileIdentifier, Self.inode(at: item.url.path) != expected {
            return
        }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        } catch {
            NSLog("⚠️ ScreenshotStateViewModel: FileManager trash failed for \(item.url.path), falling back to NSWorkspace: \(error.localizedDescription)")
            // NSWorkspace.recycle uses the Finder/Dock's own trashing route, which can
            // succeed in cases FileManager's sandboxed trash call doesn't - this is the
            // feature's core "no cleanup left behind" promise, so it's worth a second try.
            NSWorkspace.shared.recycle([item.url]) { _, error in
                if let error {
                    NSLog("⚠️ ScreenshotStateViewModel: NSWorkspace trash also failed for \(item.url.path): \(error.localizedDescription)")
                }
            }
        }
        items.removeAll { $0.id == item.id }
        ScreenshotSelectionModel.shared.deselect(item.id)
    }

    private func sweepStaleStagedCopies() {
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
        guard let drops = try? FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Self.stagedCopyMaxAge)
        for dropDir in drops {
            let created = (try? dropDir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            guard created < cutoff else { continue }
            try? FileManager.default.removeItem(at: dropDir)
        }
    }
}
