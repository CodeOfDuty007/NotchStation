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

    private var draggedItems: [ScreenshotItem] = []

    /// Starts dragging `item` out - or, if `item` is part of a larger multi-selection, every
    /// selected screenshot together (this is the "copy and paste multiple" path: Cmd-click a
    /// few, then drag any one of them, exactly like the Shelf and Finder).
    func beginDrag(for item: ScreenshotItem, from view: NSView, event: NSEvent, previewImage: NSImage) {
        // Called from an NSView's mouseDragged override: always on the main thread in
        // practice, but that method isn't itself main-actor isolated, so ask explicitly
        // rather than requiring every caller up the chain to prove it.
        let itemsToDrag: [ScreenshotItem] = MainActor.assumeIsolated {
            let selected = ScreenshotSelectionModel.shared.selectedItems(in: ScreenshotStateViewModel.shared.items)
            if selected.count > 1, selected.contains(where: { $0.id == item.id }) {
                return selected
            }
            return [item]
        }

        var draggingItems: [NSDraggingItem] = []
        for (index, dragItem) in itemsToDrag.enumerated() {
            guard let stagedURL = MainActor.assumeIsolated({ ScreenshotStateViewModel.shared.stagedCopyURL(for: dragItem) }) else { continue }

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(stagedURL.absoluteString, forType: .fileURL)
            pasteboardItem.setString(stagedURL.path, forType: .string)

            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            // Frame this at the cell's actual on-screen size, not the thumbnail's -
            // QLThumbnailGenerator hands back an NSImage sized in pixels rather than points,
            // which would otherwise make the drag image several times too large. Fan multiple
            // items out slightly so a multi-drag reads as a stack rather than one flat image.
            let offset = CGFloat(index) * 6
            let frame = NSRect(x: offset, y: -offset, width: view.bounds.width, height: view.bounds.height)
            draggingItem.setDraggingFrame(frame, contents: previewImage)
            draggingItems.append(draggingItem)
        }

        guard !draggingItems.isEmpty else { return }

        draggedItems = itemsToDrag
        isDragging = true
        view.beginDraggingSession(with: draggingItems, event: event, source: self)
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
        let items = draggedItems
        draggedItems = []
        guard operation == .copy, !items.isEmpty else { return }
        MainActor.assumeIsolated {
            for item in items {
                ScreenshotStateViewModel.shared.trashOriginal(of: item)
            }
        }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        false
    }
}
