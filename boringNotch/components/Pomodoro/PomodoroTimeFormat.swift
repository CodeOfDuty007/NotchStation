//
//  PomodoroTimeFormat.swift
//  boringNotch
//

import Foundation

/// Pure helpers for formatting and parsing the Pomodoro durations (kept free of UI/state so
/// they are trivial to reason about).
enum PomodoroTimeFormat {
    static let maxMinutes = 99
    /// Shortest allowed duration, so a timer can never be set to 0:00.
    static let minSeconds = 1
    static let maxSeconds = maxMinutes * 60 + 59

    static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, minSeconds), maxSeconds)
    }

    /// "MM:SS", rounding partial seconds up so the display reaches 00:00 exactly when time is up.
    static func display(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Parses what a user types into the editor and returns clamped total seconds, or nil if it
    /// isn't a time. Accepted: "25" (minutes), "25:30" (mm:ss), "2530" (digits only, last two
    /// are seconds), "90:5".
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, !(parts[0].isEmpty && parts[1].isEmpty),
                  let m = Int(parts[0].isEmpty ? "0" : parts[0]),
                  let s = Int(parts[1].isEmpty ? "0" : parts[1]),
                  m >= 0, s >= 0, s < 60 else { return nil }
            // Cap before multiplying so a pasted huge number can't overflow.
            return clamp(min(m, maxMinutes + 1) * 60 + s)
        }

        guard trimmed.allSatisfy(\.isNumber), let n = Int(trimmed.prefix(9)) else { return nil }
        if trimmed.count <= 2 { return clamp(n * 60) }       // "25" -> 25 min
        let m = n / 100, sec = n % 100
        guard sec < 60 else { return nil }
        return clamp(m * 60 + sec)
    }
}
