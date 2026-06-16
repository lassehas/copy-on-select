//
//  SelectionWatcher.swift
//  copy-on-select
//
//  Watches for mouse drag-selection and keyboard shift-selection gestures
//  system-wide and copies the currently selected text to the clipboard,
//  mimicking terminal copy-on-select.
//

import AppKit
import ApplicationServices

/// Detects a text-selection gesture and copies the selection.
///
/// Strategy:
///  1. A `CGEventTap` observes left mouse down/dragged/up and key-down globally.
///  2. A mouse drag is a left-down followed by movement, then a left-up.
///  3. A keyboard selection is Shift + a navigation key (arrows, Home/End,
///     optionally with Cmd/Option). Repeated keystrokes are debounced so we
///     copy once, after the selection settles.
///  4. We read the focused UI element's `kAXSelectedTextAttribute`.
///  5. If AX yields nothing (app doesn't expose selection — some web/Electron
///     apps like VS Code), we fall back to synthesizing Cmd+C and reading the
///     pasteboard. For keyboard selection this fallback runs only after the
///     debounce, so the user has paused/released and the synthetic copy won't
///     collide with keys they're still holding.
@MainActor
final class SelectionWatcher {
    static let shared = SelectionWatcher()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Did the pointer move while the button was held? Distinguishes a drag
    /// (selection) from a plain click.
    private var didDragSinceMouseDown = false
    private var mouseDownLocation: CGPoint = .zero

    /// Movement (in points) past which we treat the gesture as a drag.
    private let dragThreshold: CGFloat = 3.0

    /// True once a Shift+nav keystroke is seen; cleared when we capture. The
    /// primary trigger is Shift being released (`flagsChanged`), so a pause
    /// mid-selection while Shift is held never fires a partial capture.
    private var pendingKeyboardSelection = false

    /// Safety-net timer: if we somehow miss the Shift-release event, capture
    /// after the user stops pressing keys for this long. Generous so it rarely
    /// pre-empts a real Shift-release.
    private var keyboardSelectionDebounce: DispatchWorkItem?
    private let keyboardSelectionDelay: TimeInterval = 1.2

    /// Last text we wrote to the pasteboard, to avoid pushing duplicates (e.g.
    /// repeated captures of a growing then-finalized selection).
    private var lastCopiedText: String?

    private(set) var isRunning = false

    private init() {}

    // MARK: - Lifecycle

    /// Starts watching. Requires Accessibility permission to be granted;
    /// returns `false` (and does nothing) if the event tap can't be created.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        // Listen-only tap: we never modify or swallow events.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                // Hop to the main actor's state. The tap is attached to the
                // main run loop, so this callback already runs on the main
                // thread; the singleton access is therefore safe.
                MainActor.assumeIsolated {
                    SelectionWatcher.shared.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isRunning = true
        return true
    }

    func stop() {
        guard isRunning, let tap = eventTap else { return }
        keyboardSelectionDebounce?.cancel()
        keyboardSelectionDebounce = nil
        pendingKeyboardSelection = false
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            didDragSinceMouseDown = false
            mouseDownLocation = event.location

        case .leftMouseDragged:
            if !didDragSinceMouseDown {
                let dx = event.location.x - mouseDownLocation.x
                let dy = event.location.y - mouseDownLocation.y
                if (dx * dx + dy * dy) >= (dragThreshold * dragThreshold) {
                    didDragSinceMouseDown = true
                }
            }

        case .leftMouseUp:
            if didDragSinceMouseDown {
                didDragSinceMouseDown = false
                // Defer slightly: let the target app finalize its selection
                // state before we read it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    self.captureSelection()
                }
            }

        case .keyDown:
            if isShiftSelectionKey(event) {
                // Mark a selection in progress and arm the safety-net timer.
                // We don't capture here — the real trigger is Shift-release.
                pendingKeyboardSelection = true
                scheduleKeyboardCapture()
            }

        case .flagsChanged:
            // Shift released while a selection was in progress → selection is
            // final. Capture now.
            if pendingKeyboardSelection && !event.flags.contains(.maskShift) {
                fireKeyboardCapture()
            }

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system can disable a tap that is slow or on user input;
            // re-enable it so we keep working.
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }

        default:
            break
        }
    }

    // MARK: - Keyboard selection

    /// Virtual key codes for navigation keys that, combined with Shift, extend
    /// a text selection.
    private static let navigationKeyCodes: Set<Int64> = [
        0x7B, // left arrow
        0x7C, // right arrow
        0x7D, // down arrow
        0x7E, // up arrow
        0x73, // home
        0x77, // end
        0x74, // page up
        0x79, // page down
    ]

    /// True when the event is a navigation key held with Shift (and only the
    /// allowed selection modifiers — Cmd/Option/Control). Cmd+A is intentionally
    /// excluded by requiring Shift.
    private func isShiftSelectionKey(_ event: CGEvent) -> Bool {
        let flags = event.flags
        guard flags.contains(.maskShift) else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        return Self.navigationKeyCodes.contains(keyCode)
    }

    /// (Re)arms the safety-net timer. The normal path captures on Shift-release;
    /// this only fires if that event is somehow missed.
    private func scheduleKeyboardCapture() {
        keyboardSelectionDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fireKeyboardCapture()
        }
        keyboardSelectionDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + keyboardSelectionDelay, execute: work)
    }

    /// Resolves a pending keyboard selection exactly once: clears the in-progress
    /// flag, cancels the safety-net timer, and captures.
    private func fireKeyboardCapture() {
        guard pendingKeyboardSelection else { return }
        pendingKeyboardSelection = false
        keyboardSelectionDebounce?.cancel()
        keyboardSelectionDebounce = nil
        captureKeyboardSelection()
    }

    /// Capture for keyboard selections. Tries AX first; if the app doesn't
    /// expose its selection (e.g. Electron editors like VS Code), falls back to
    /// a synthetic Cmd+C. The fallback is safe here because it runs only once
    /// the selection is final (Shift released), not mid-keystroke.
    private func captureKeyboardSelection() {
        if let text = selectedTextViaAccessibility(), !text.isEmpty {
            copyToPasteboard(text)
            return
        }
        captureViaSyntheticCopy()
    }

    // MARK: - Capture

    private func captureSelection() {
        if let text = selectedTextViaAccessibility(), !text.isEmpty {
            copyToPasteboard(text)
            return
        }
        // Fallback: synthesize Cmd+C and read what lands on the pasteboard.
        captureViaSyntheticCopy()
    }

    /// Reads the selected text of the system-wide focused UI element.
    private func selectedTextViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()

        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused else {
            return nil
        }
        // Force-cast is safe: a successful AX copy of a UI element attribute
        // always returns an AXUIElement.
        let axElement = element as! AXUIElement

        var selected: AnyObject?
        guard AXUIElementCopyAttributeValue(
            axElement, kAXSelectedTextAttribute as CFString, &selected
        ) == .success, let text = selected as? String else {
            return nil
        }
        return text
    }

    /// Sends Cmd+C and reads the resulting pasteboard contents. Restores
    /// nothing — the whole point is to leave the selection on the clipboard.
    private func captureViaSyntheticCopy() {
        let pasteboard = NSPasteboard.general
        let changeCountBefore = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let cmdFlag: CGEventFlags = .maskCommand
        let cKey: CGKeyCode = 8 // 'c'

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        keyDown?.flags = cmdFlag
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        keyUp?.flags = cmdFlag

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        // Give the target app a moment to service the copy, then record what
        // landed on the pasteboard (if it changed) so the dedupe in
        // copyToPasteboard also covers this path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if changeCountBefore != pasteboard.changeCount {
                self.lastCopiedText = pasteboard.string(forType: .string)
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        // Skip duplicates: repeated captures of the same selection (or a
        // safety-net timer firing after Shift-release already captured) must
        // not spam the clipboard.
        guard text != lastCopiedText else { return }
        lastCopiedText = text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
