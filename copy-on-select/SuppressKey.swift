//
//  SuppressKey.swift
//  copy-on-select
//
//  The user-configurable modifier that, when held during a selection,
//  suppresses the copy. Persisted in UserDefaults as a raw modifier-flag mask.
//

import AppKit

/// A suppressor modifier combination, stored as the raw value of an
/// `NSEvent.ModifierFlags` mask restricted to the device-independent modifiers.
struct SuppressKey: Equatable {
    /// Raw `NSEvent.ModifierFlags.rawValue`, masked to device-independent flags.
    let rawFlags: UInt

    private static let defaultsKey = "suppressModifierFlags"

    /// Only these modifiers are meaningful as a hold-while-selecting suppressor.
    /// Shift is excluded: it is the keyboard-selection trigger itself.
    static let allowedFlags: NSEvent.ModifierFlags = [.control, .option, .command]

    /// The current setting, read fresh from UserDefaults. Defaults to Control.
    static var current: SuppressKey {
        let stored = UserDefaults.standard.object(forKey: defaultsKey) as? UInt
        guard let stored else { return SuppressKey(rawFlags: NSEvent.ModifierFlags.control.rawValue) }
        return SuppressKey(rawFlags: stored)
    }

    /// Persists this as the current setting.
    func save() {
        UserDefaults.standard.set(rawFlags, forKey: Self.defaultsKey)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawFlags).intersection(Self.allowedFlags)
    }

    /// True when at least one allowed modifier is set. A combo with no allowed
    /// modifier (e.g. a bare letter key) cannot be held during a selection.
    var isValid: Bool { !modifierFlags.isEmpty }

    /// The equivalent `CGEventFlags`, for matching against event-tap flags.
    var cgFlags: CGEventFlags {
        let flags = modifierFlags
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        return result
    }

    /// Human-readable glyphs, e.g. "⌃" or "⌃⌥".
    var displayString: String {
        let flags = modifierFlags
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.command) { s += "⌘" }
        return s.isEmpty ? "—" : s
    }

    /// Builds a suppress key from a recorded key event, keeping only the
    /// allowed modifiers. Returns `nil` if no allowed modifier was held.
    static func fromRecorded(_ flags: NSEvent.ModifierFlags) -> SuppressKey? {
        let masked = flags.intersection(allowedFlags)
        guard !masked.isEmpty else { return nil }
        return SuppressKey(rawFlags: masked.rawValue)
    }
}
