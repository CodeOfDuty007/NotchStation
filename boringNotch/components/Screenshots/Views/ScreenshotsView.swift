//
//  ScreenshotsView.swift
//  boringNotch
//

import SwiftUI

/// Notch tab showing the ten most recent screenshots as a horizontally-snapping wheel.
/// Select one (click, or scroll it to center), press Space for a Quick Look preview, or drag
/// it straight out to wherever it's needed - the original is moved to the Trash the instant
/// that drag is dropped, so there's nothing left to clean up afterwards.
struct ScreenshotsView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject private var state = ScreenshotStateViewModel.shared
    @StateObject private var quickLookService = QuickLookService()

    var body: some View {
        panel
            .onAppear {
                state.restoreAccessIfAvailable()
                wireSpacebarPreview()
                ScreenshotSpacebarTapController.shared.activate()
            }
            .onDisappear {
                ScreenshotSpacebarTapController.shared.deactivate()
                // Nothing should stay "selected" once this tab isn't showing - it's the
                // signal the spacebar tap uses to decide whether Space means anything.
                state.selectedID = nil
            }
            .onChange(of: state.selectedID) { _, _ in
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

            Button {
                _ = state.requestFolderAccess()
            } label: {
                Text("Choose Folder…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
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
                    ScreenshotWheelItemView(item: item)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 60, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: selectedIDBinding, anchor: .center)
        .scrollIndicators(.never)
    }

    private var selectedIDBinding: Binding<String?> {
        Binding(get: { state.selectedID }, set: { state.selectedID = $0 })
    }

    private var infoBar: some View {
        HStack {
            if let item = state.selectedItem {
                Text(item.captureDate.formatted(date: .abbreviated, time: .shortened))
                Spacer(minLength: 8)
                Text("\(item.fileSizeKB) KB")
            } else {
                Text("Select a screenshot, press Space to preview, or drag it out")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.gray)
        .frame(maxWidth: .infinity)
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
            guard let item = ScreenshotStateViewModel.shared.selectedItem else { return false }

            if quickLook.isQuickLookOpen {
                quickLook.hide()
                return true
            }

            guard Self.isMouseInsideOpenNotch(of: viewModel) else { return false }
            // The screenshots folder's security scope is already held open for as long as
            // it's being watched - these child URLs don't need (and don't have) their own.
            quickLook.show(urls: [item.url], selectFirst: true, requiresSecurityScope: false)
            return true
        }
    }

    private static func isMouseInsideOpenNotch(of vm: BoringViewModel) -> Bool {
        guard vm.notchState == .open,
              let uuid = vm.screenUUID,
              let screen = NSScreen.screen(withUUID: uuid) else { return false }

        let screenFrame = screen.frame
        let notchRegion = CGRect(
            x: screenFrame.midX - openNotchSize.width / 2,
            y: screenFrame.maxY - openNotchSize.height,
            width: openNotchSize.width,
            height: openNotchSize.height
        )
        return notchRegion.contains(NSEvent.mouseLocation)
    }

    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen, let item = state.selectedItem else { return }
        quickLookService.updateSelection(urls: [item.url])
    }
}
