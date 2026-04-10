import Foundation

enum HotkeySignal: Sendable, Equatable {
    case pressed
    case released
}

struct HotkeyToggleGate: Sendable, Equatable {
    private(set) var isArmed = false
    private(set) var lastToggleAt: Date?
    let debounceWindowSeconds: TimeInterval

    init(debounceWindowSeconds: TimeInterval = 0.25) {
        self.debounceWindowSeconds = debounceWindowSeconds
    }

    mutating func consume(_ signal: HotkeySignal, now: Date = Date()) -> Bool {
        switch signal {
        case .pressed:
            isArmed = true
            return false

        case .released:
            guard isArmed else {
                return false
            }
            isArmed = false

            if let lastToggleAt,
               now.timeIntervalSince(lastToggleAt) < debounceWindowSeconds {
                return false
            }

            self.lastToggleAt = now
            return true
        }
    }

    mutating func reset() {
        isArmed = false
        lastToggleAt = nil
    }
}

struct HotkeyDoubleTapGate: Sendable, Equatable {
    private(set) var isArmed = false
    private(set) var pendingTapAt: Date?
    let activationWindowSeconds: TimeInterval

    init(activationWindowSeconds: TimeInterval = 0.35) {
        self.activationWindowSeconds = activationWindowSeconds
    }

    mutating func consume(_ signal: HotkeySignal, now: Date = Date()) -> Bool {
        switch signal {
        case .pressed:
            guard !isArmed else {
                return false
            }
            isArmed = true
            return false

        case .released:
            guard isArmed else {
                return false
            }
            isArmed = false
            return registerTap(now: now)
        }
    }

    mutating func registerTap(now: Date = Date()) -> Bool {
        if let pendingTapAt,
           now.timeIntervalSince(pendingTapAt) <= activationWindowSeconds {
            self.pendingTapAt = nil
            return true
        }

        pendingTapAt = now
        return false
    }

    mutating func reset() {
        isArmed = false
        pendingTapAt = nil
    }
}
