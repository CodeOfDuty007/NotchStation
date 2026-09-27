//
//  ScreenshotWheelItemView.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// One cell in the screenshots wheel: a thumbnail that can be selected with a click and
/// dragged straight out to Finder, Mail, Slack, etc. Dragging is handled by an
/// `NSViewRepresentable` (SwiftUI has no drag-out primitive that hands back a real
/// `NSDraggingSource`), which starts the session on `ScreenshotDragSource.shared` so it
/// survives the tab being torn down mid-drag (see that type's doc comment).
struct ScreenshotWheelItemView: View {
    let item: ScreenshotItem

    @ObservedObject private var state = ScreenshotStateViewModel.shared
    @State private var thumbnail: NSImage?

    private static let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()

    private var isSelected: Bool { state.selectedID == item.id }

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(isSelected ? 0.16 : 0.07))
            .overlay {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.85) : Color.clear, lineWidth: 2)
            }
            .frame(width: 96, height: 72)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                DraggableScreenshotHandler(
                    previewImage: thumbnail ?? Self.placeholder,
                    onSelect: { state.selectedID = item.id },
                    onBeginDrag: { view, event, previewImage in
                        ScreenshotDragSource.shared.beginDrag(for: item, from: view, event: event, previewImage: previewImage)
                    }
                )
            }
            .task(id: item.id) {
                thumbnail = await ThumbnailService.shared.thumbnail(for: item.url, size: CGSize(width: 220, height: 160))
            }
            .scrollTransition { content, phase in
                content
                    .scaleEffect(phase.isIdentity ? 1 : 0.85)
                    .opacity(phase.isIdentity ? 1 : 0.55)
            }
    }
}

// MARK: - Drag/click handling

private struct DraggableScreenshotHandler: NSViewRepresentable {
    let previewImage: NSImage
    let onSelect: () -> Void
    let onBeginDrag: (NSView, NSEvent, NSImage) -> Void

    func makeNSView(context: Context) -> DraggableScreenshotNSView {
        let view = DraggableScreenshotNSView()
        view.previewImage = previewImage
        view.onSelect = onSelect
        view.onBeginDrag = onBeginDrag
        return view
    }

    func updateNSView(_ nsView: DraggableScreenshotNSView, context: Context) {
        nsView.previewImage = previewImage
        nsView.onSelect = onSelect
        nsView.onBeginDrag = onBeginDrag
    }

    final class DraggableScreenshotNSView: NSView {
        var previewImage: NSImage?
        var onSelect: (() -> Void)?
        var onBeginDrag: ((NSView, NSEvent, NSImage) -> Void)?

        private var mouseDownEvent: NSEvent?
        private var didDrag = false
        private let dragThreshold: CGFloat = 3.0

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            didDrag = false
            // Selecting here (rather than on mouseUp) would fight `.scrollPosition`'s two-way
            // binding: selecting scrolls the wheel to center that cell, which happens just as
            // the same click starts turning into a drag.
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownEvent else {
                super.mouseDragged(with: event)
                return
            }

            let distance = hypot(
                event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                event.locationInWindow.y - mouseDownEvent.locationInWindow.y
            )
            guard distance > dragThreshold else {
                super.mouseDragged(with: event)
                return
            }

            didDrag = true
            self.mouseDownEvent = nil
            guard let previewImage else { return }
            onBeginDrag?(self, event, previewImage)
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDownEvent = nil }
            guard !didDrag, mouseDownEvent != nil else { return }
            onSelect?()
        }
    }
}
