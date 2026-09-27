//
//  ScreenshotSelectionModel.swift
//  boringNotch
//

import Foundation

/// Which screenshots in the wheel are selected. Plain click replaces the selection with just
/// that item; Cmd-click toggles it into/out of a multi-selection (see `ScreenshotWheelItemView`),
/// mirroring how Finder and the Shelf (`ShelfSelectionModel`) handle multi-select.
@MainActor
final class ScreenshotSelectionModel: ObservableObject {
    static let shared = ScreenshotSelectionModel()

    @Published private(set) var selectedIDs: Set<String> = []

    private init() {}

    var hasSelection: Bool { !selectedIDs.isEmpty }

    func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }

    func selectSingle(_ id: String) {
        selectedIDs = [id]
    }

    func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func deselect(_ id: String) {
        selectedIDs.remove(id)
    }

    func clear() {
        selectedIDs.removeAll()
    }

    /// Selected items, in the wheel's own (most-recent-first) order.
    func selectedItems(in items: [ScreenshotItem]) -> [ScreenshotItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    /// Drops any selected id that's no longer in the current item list - e.g. a screenshot
    /// aged out of the ten most recent, or was trashed from another selection entirely.
    func pruneSelection(toExisting items: [ScreenshotItem]) {
        let validIDs = Set(items.map(\.id))
        selectedIDs = selectedIDs.intersection(validIDs)
    }
}
