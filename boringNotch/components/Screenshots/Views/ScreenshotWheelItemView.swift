//
//  ScreenshotWheelItemView.swift
//  boringNotch
//

import AppKit
import SwiftUI

/// One cell in the screenshots wheel: a thumbnail that can be selected with a click (Cmd-click
/// to add to a multi-selection), dragged straight out to Finder, Mail, Slack, etc., or deleted
/// on the spot with the hover button - handy for a misclicked screenshot you never meant to
/// keep around. Dragging is handled by an `NSViewRepresentable` (SwiftUI has no drag-out
/// primitive that hands back a real `NSDraggingSource`), which starts the session on
/// `ScreenshotDragSource.shared` so it survives the tab being torn down mid-drag (see that
/// type's doc comment).
struct ScreenshotWheelItemView: View {
    let item: ScreenshotItem
    /// One-way: a click centers its cell in the wheel. Not bound back from selection, since
    /// selection is now a `Set` (Cmd-click multi-select) and can't drive a single scroll target.
    @Binding var centeredID: String?

    @ObservedObject private var state = ScreenshotStateViewModel.shared
    @ObservedObject private var selection = ScreenshotSelectionModel.shared
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    private static let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()

    private var isSelected: Bool { selection.isSelected(item.id) }

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
                    onSelect: { event in
                        if event.modifierFlags.contains(.command) {
                            selection.toggle(item.id)
                        } else {
                            selection.selectSingle(item.id)
                        }
                        centeredID = item.id
                    },
                    onBeginDrag: { view, event, previewImage in
                        ScreenshotDragSource.shared.beginDrag(for: item, from: view, event: event, previewImage: previewImage)
                    },
                    onHoverChange: { hovering in isHovering = hovering }
                )
            }
            // Declared after the drag handler so it - not the drag NSView beneath it - gets the
            // click in this corner.
            .overlay(alignment: .topTrailing) {
                if isHovering {
                    Button {
                        state.trashOriginal(of: item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help("Move to Trash")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(3)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
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

// MARK: - Drag/click/hover handling

private struct DraggableScreenshotHandler: NSViewRepresentable {
    let previewImage: NSImage
    let onSelect: (NSEvent) -> Void
    let onBeginDrag: (NSView, NSEvent, NSImage) -> Void
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> DraggableScreenshotNSView {
        let view = DraggableScreenshotNSView()
        view.previewImage = previewImage
        view.onSelect = onSelect
        view.onBeginDrag = onBeginDrag
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: DraggableScreenshotNSView, context: Context) {
        nsView.previewImage = previewImage
        nsView.onSelect = onSelect
        nsView.onBeginDrag = onBeginDrag
        nsView.onHoverChange = onHoverChange
    }

    final class DraggableScreenshotNSView: NSView {
        var previewImage: NSImage?
        var onSelect: ((NSEvent) -> Void)?
        var onBeginDrag: ((NSView, NSEvent, NSImage) -> Void)?
        var onHoverChange: ((Bool) -> Void)?

        private var trackingArea: NSTrackingArea?
        private var mouseDownEvent: NSEvent?
        private var didDrag = false
        private let dragThreshold: CGFloat = 3.0

        // SwiftUI's own `.onHover` doesn't see through this NSView, so hover has to be tracked
        // at the AppKit level directly.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChange?(false)
        }

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
            onSelect?(event)
        }
    }
}
