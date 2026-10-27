import Foundation
import XCTest
@testable import ScreenshotDragLifecycle

final class ScreenshotDragBatchTests: XCTestCase {
    private func stagedURL(for name: String) -> URL {
        URL(fileURLWithPath: "/temporary-drag/\(name).png")
    }

    func testPartialStagingFailureNeverMakesFailedOriginalEligible() {
        let batch = ScreenshotDragBatch(selected: ["first", "second"]) { name in
            name == "first" ? self.stagedURL(for: name) : nil
        }

        XCTAssertEqual(batch.stagedItems.map(\.original), ["first"])
        XCTAssertEqual(batch.stagedItems.map(\.copyURL), [stagedURL(for: "first")])
        XCTAssertEqual(batch.originalsEligibleForTrash(didCopy: true) { _ in true }, ["first"])
    }

    func testMixedSuccessBatchKeepsStagedEntriesInSelectionOrder() {
        let batch = ScreenshotDragBatch(selected: ["one", "two", "three", "four"]) { name in
            ["one", "three"].contains(name) ? self.stagedURL(for: name) : nil
        }

        XCTAssertEqual(batch.stagedItems.map(\.original), ["one", "three"])
        XCTAssertEqual(batch.originalsEligibleForTrash(didCopy: true) { _ in true }, ["one", "three"])
    }

    func testCancelledDropKeepsEveryOriginal() {
        let batch = ScreenshotDragBatch(selected: ["one", "two"]) { self.stagedURL(for: $0) }

        XCTAssertTrue(batch.originalsEligibleForTrash(didCopy: false) { _ in
            XCTFail("A cancelled drag must not inspect copies for trash eligibility")
            return true
        }.isEmpty)
    }

    func testSuccessfulMultiFileCopyMakesEachStagedOriginalEligible() {
        let batch = ScreenshotDragBatch(selected: ["one", "two", "three"]) { self.stagedURL(for: $0) }

        XCTAssertEqual(batch.stagedItems.map(\.copyURL), [
            stagedURL(for: "one"), stagedURL(for: "two"), stagedURL(for: "three")
        ])
        XCTAssertEqual(
            batch.originalsEligibleForTrash(didCopy: true) { _ in true },
            ["one", "two", "three"]
        )
    }

    func testUnavailableStagedFileAtCompletionKeepsItsOriginal() {
        let batch = ScreenshotDragBatch(selected: ["one", "two"]) { self.stagedURL(for: $0) }

        XCTAssertEqual(
            batch.originalsEligibleForTrash(didCopy: true) { $0 == self.stagedURL(for: "one") },
            ["one"]
        )
    }

    func testCompleteStagingFailureHasNoDragItemsOrTrashCandidates() {
        let batch = ScreenshotDragBatch(selected: ["one", "two"]) { _ in nil as URL? }

        XCTAssertTrue(batch.stagedItems.isEmpty)
        XCTAssertTrue(batch.originalsEligibleForTrash(didCopy: true) { _ in true }.isEmpty)
    }
}
