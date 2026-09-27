//
//  ScreenshotDragSource.swift
//  boringNotch
//

import AppKit

/// The `NSDraggingSource` for screenshots dragged out of the notch.
///
/// This is deliberately a standalone object instead of the SwiftUI-hosted `NSView` that
/// starts the drag. `AppDelegate` can force `coordinator.currentView = .shelf` when a drag
/// enters the notch region, which would tear down the Screenshots tab's view tree; a drag
/// source tied to that view could then lose its `endedAt` callback along with it. This
/// singleton keeps receiving it regardless of what happens to the view that started the drag.
final class ScreenshotDragSource: NSObject, NSDraggingSource {
    static let shared = ScreenshotDragSource()

    private override init() { super.init() }

    /// Whether a screenshot drag is currently in flight, so the notch-region drag detector
    /// can skip its usual "switch to Shelf" behavior for a drag that starts on our own tab.
    private(set) var isDragging = false

    private var draggedItem: ScreenshotItem?

    func beginDrag(for item: ScreenshotItem, from view: NSView, event: NSEvent, previewImage: NSImage) {
        // Called from an NSView's mouseDragged override: always on the main thread in
        // practice, but that method isn't itself main-actor isolated, so ask explicitly
        // rather than requiring every caller up the chain to prove it.
        guard let stagedURL = MainActor.assumeIsolated({ ScreenshotStateViewModel.shared.stagedCopyURL(for: item) }) else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(stagedURL.absoluteString, forType: .fileURL)
        pasteboardItem.setString(stagedURL.path, forType: .string)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // Frame this at the cell's actual on-screen size, not the thumbnail's - QLThumbnailGenerator
        // hands back an NSImage sized in pixels rather than points, which would otherwise make the
        // drag image several times too large.
        draggingItem.setDraggingFrame(NSRect(origin: .zero, size: view.bounds.size), contents: previewImage)

        draggedItem = item
        isDragging = true
        view.beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            // Copy only: a "move" into the destination could relocate the original file
            // itself, and we must not trash whatever now sits at wherever that landed.
            return .copy
        case .withinApplication:
            // Never let a screenshot be "dropped" onto e.g. the Shelf - that would trash the
            // original for a drop the Shelf just treats as a no-op file reference anyway.
            return []
        @unknown default:
            return []
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        let item = draggedItem
        draggedItem = nil
        guard operation == .copy, let item else { return }
        ScreenshotStateViewModel.shared.trashOriginal(of: item)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        false
    }
}
