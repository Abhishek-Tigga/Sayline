import CoreGraphics

/// The set of standard modifier keys Sayline can use as the hold-to-talk
/// hotkey. Restricted to modifiers (not arbitrary key combos) because the
/// whole hotkey detection scheme relies on a clean flagsChanged down/up
/// signal, which regular keys don't give as naturally.
enum HotkeyOption: Int64, CaseIterable {
    case rightOption = 61
    case leftOption = 58
    case rightCommand = 54
    case leftCommand = 55
    case rightControl = 62
    case leftControl = 59
    case rightShift = 60
    case leftShift = 56
    case function = 63

    var displayName: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .leftOption: return "Left Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .leftCommand: return "Left Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .leftControl: return "Left Control (⌃)"
        case .rightShift: return "Right Shift (⇧)"
        case .leftShift: return "Left Shift (⇧)"
        case .function: return "Fn (Globe)"
        }
    }

    /// The short symbol shown in "Hold ⌥ to talk" style hints.
    var shortSymbol: String {
        switch self {
        case .rightOption, .leftOption: return "⌥"
        case .rightCommand, .leftCommand: return "⌘"
        case .rightControl, .leftControl: return "⌃"
        case .rightShift, .leftShift: return "⇧"
        case .function: return "Fn"
        }
    }

    var flagMask: CGEventFlags {
        switch self {
        case .rightOption, .leftOption: return .maskAlternate
        case .rightCommand, .leftCommand: return .maskCommand
        case .rightControl, .leftControl: return .maskControl
        case .rightShift, .leftShift: return .maskShift
        case .function: return .maskSecondaryFn
        }
    }
}
