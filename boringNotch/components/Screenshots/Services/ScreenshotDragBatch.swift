//
//  ScreenshotDragBatch.swift
//  boringNotch
//

import Foundation

/// Keeps each original paired with the disposable file actually offered to AppKit.
/// An item whose staging failed never enters the drag or its completion cleanup.
struct ScreenshotDragBatch<Original> {
    struct StagedItem {
        let original: Original
        let copyURL: URL
    }

    let stagedItems: [StagedItem]

    init(selected: [Original], stage: (Original) -> URL?) {
        stagedItems = selected.compactMap { original in
            guard let copyURL = stage(original) else { return nil }
            return StagedItem(original: original, copyURL: copyURL)
        }
    }

    /// A successful copy operation acknowledges the drag as a whole. Restrict cleanup
    /// to originals that were published with an available staged file.
    func originalsEligibleForTrash(
        didCopy: Bool,
        stagedCopyExists: (URL) -> Bool
    ) -> [Original] {
        guard didCopy else { return [] }
        return stagedItems.compactMap { staged in
            stagedCopyExists(staged.copyURL) ? staged.original : nil
        }
    }
}
