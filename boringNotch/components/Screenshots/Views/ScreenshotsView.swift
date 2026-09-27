//
//  ScreenshotsView.swift
//  boringNotch
//

import SwiftUI

/// Notch tab showing the ten most recent screenshots as a horizontally-snapping wheel.
/// Click to select one, Cmd-click to select several, press Space for a Quick Look preview, or
/// drag the selection straight out to wherever it's needed - the originals are moved to the
/// Trash the instant that drag is dropped, so there's nothing left to clean up afterwards. The
/// hover button on a cell deletes just that one screenshot on the spot, for a misclick.
struct ScreenshotsView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject private var state = ScreenshotStateViewModel.shared
    @StateObject private var selection = ScreenshotSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()

    @State private var centeredID: String?
    @State private var spacebarNeedsAccessibility = false

    var body: some View {
        panel
            .onAppear {
                state.restoreAccessIfAvailable()
                wireSpacebarPreview()
                ScreenshotSpacebarTapController.shared.activate()
                spacebarNeedsAccessibility = !ScreenshotSpacebarTapController.shared.isTapInstalled
            }
            .onDisappear {
                ScreenshotSpacebarTapController.shared.deactivate()
                // Nothing should stay "selected" once this tab isn't showing - it's the
                // signal the spacebar tap uses to decide whether Space means anything.
                selection.clear()
            }
            .onChange(of: selection.selectedIDs) { _, _ in
                updateQuickLookSelection()
            }
            .quickLookPresenter(using: quickLookService)
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding()
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
    }

    @ViewBuilder
    private var content: some View {
        if !state.hasFolderAccess {
            grantAccessState
        } else if state.isEmpty {
            emptyState
        } else {
            VStack(spacing: 8) {
                wheel
                infoBar
            }
        }
    }

    private var grantAccessState: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, .gray)
                .imageScale(.large)

            Text("Grant access to your screenshots folder to get started")
                .foregroundStyle(.gray)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.medium)
                .multilineTextAlignment(.center)

            pillButton("Choose Folder…") {
                _ = state.requestFolderAccess()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, .gray)
                .imageScale(.large)

            Text("Your last 10 screenshots will show up here")
                .foregroundStyle(.gray)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wheel: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(state.items) { item in
                    ScreenshotWheelItemView(item: item, centeredID: $centeredID)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 60, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centeredID, anchor: .center)
        .scrollIndicators(.never)
    }

    private var infoBar: some View {
        VStack(spacing: 4) {
            HStack {
                switch selectedItemsInOrder.count {
                case 0:
                    Text("Select a screenshot, press Space to preview, or drag it out")
                case 1:
                    let item = selectedItemsInOrder[0]
                    Text(item.captureDate.formatted(date: .abbreviated, time: .shortened))
                    Spacer(minLength: 8)
                    Text("\(item.fileSizeKB) KB")
                default:
                    Text("\(selectedItemsInOrder.count) screenshots selected")
                    Spacer(minLength: 8)
                    Text("\(selectedItemsInOrder.reduce(0) { $0 + $1.fileSizeKB }) KB total")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.gray)

            if spacebarNeedsAccessibility {
                HStack(spacing: 4) {
                    Text("Space preview needs Accessibility")
                    Button("Enable") {
                        Task {
                            _ = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                            ScreenshotSpacebarTapController.shared.retryInstall()
                            spacebarNeedsAccessibility = !ScreenshotSpacebarTapController.shared.isTapInstalled
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .font(.system(size: 9))
                .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var selectedItemsInOrder: [ScreenshotItem] {
        selection.selectedItems(in: state.items)
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    /// Wires Space to toggle Quick Look for whatever's selected. The Screenshots view's own
    /// `QuickLookService` (not `self`, a value type) and `vm` are captured so the closure
    /// stays valid, and geo-fenced to this screen, for as long as this tab is on screen.
    ///
    /// Because the notch window never becomes key, the tap that makes this possible
    /// (`ScreenshotSpacebarTapController`) has to swallow Space *before* AppKit knows which
    /// app the user thinks they're talking to. Closing an already-open preview is always safe
    /// to consume. Opening one only is, when the cursor is actually over this screen's open
    /// notch - otherwise a bare Space typed anywhere else on the system, while a screenshot
    /// merely happens to be selected, would get silently eaten instead of reaching whatever
    /// app is really focused.
    private func wireSpacebarPreview() {
        let quickLook = quickLookService
        let viewModel = vm
        ScreenshotSpacebarTapController.shared.onSpacebarPressed = {
            let items = ScreenshotSelectionModel.shared.selectedItems(in: ScreenshotStateViewModel.shared.items)
            guard !items.isEmpty else {
                NSLog("🔵 ScreenshotsView: spacebar ignored - nothing selected")
                return false
            }

            if quickLook.isQuickLookOpen {
                quickLook.hide()
                return true
            }

            let gate = Self.isMouseInsideOpenNotch(of: viewModel)
            guard gate.result else {
                NSLog("🔵 ScreenshotsView: spacebar ignored - \(gate.reason)")
                return false
            }

            // The screenshots folder's security scope is already held open for as long as
            // it's being watched - these child URLs don't need (and don't have) their own.
            quickLook.show(urls: items.map(\.url), selectFirst: true, requiresSecurityScope: false)
            return true
        }
    }

    private static func isMouseInsideOpenNotch(of vm: BoringViewModel) -> (result: Bool, reason: String) {
        guard vm.notchState == .open else {
            return (false, "notch isn't open")
        }
        // Fall back to the main screen if this window's own screenUUID hasn't been assigned
        // yet - better to occasionally allow a preview from the wrong display than to silently
        // never allow one because of a geometry lookup that came back empty.
        guard let screen = vm.screenUUID.flatMap(NSScreen.screen(withUUID:)) ?? NSScreen.main else {
            return (false, "no screen to test against")
        }

        let screenFrame = screen.frame
        let notchRegion = CGRect(
            x: screenFrame.midX - openNotchSize.width / 2,
            y: screenFrame.maxY - openNotchSize.height,
            width: openNotchSize.width,
            height: openNotchSize.height
        )
        let mouse = NSEvent.mouseLocation
        guard notchRegion.contains(mouse) else {
            return (false, "cursor at \(mouse) is outside the open-notch rect \(notchRegion)")
        }
        return (true, "ok")
    }

    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen else { return }
        let urls = selectedItemsInOrder.map(\.url)
        guard !urls.isEmpty else {
            quickLookService.hide()
            return
        }
        quickLookService.updateSelection(urls: urls)
    }
}
