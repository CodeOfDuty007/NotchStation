//
//  AppDelegate+AntiDoomscroll.swift
//  boringNotch
//

import Foundation

extension AppDelegate {
    /// Registered once at launch so counting continues while the notch is closed.
    func setupAntiDoomscroll() {
        Task { @MainActor in AntiDoomscrollManager.shared.start() }
    }
}
