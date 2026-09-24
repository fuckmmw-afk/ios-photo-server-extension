import Foundation

struct ResolutionConsent {
    enum Choice: Equatable {
        case applyAnyway
        case keepOriginal
    }

    private(set) var requiresChoice = false
    private(set) var choice: Choice?

    var needsChoice: Bool { requiresChoice && choice == nil }
    var mayApply: Bool { !requiresChoice || choice == .applyAnyway }
    var keepsOriginal: Bool { requiresChoice && choice == .keepOriginal }

    mutating func presentWarning() {
        requiresChoice = true
        choice = nil
    }

    mutating func choose(_ choice: Choice) {
        guard requiresChoice else { return }
        self.choice = choice
    }
}
