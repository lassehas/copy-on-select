//
//  SuppressKeyRecorder.swift
//  copy-on-select
//
//  A small modal panel that captures the next modifier combination the user
//  presses and reports it back as a SuppressKey.
//

import AppKit

/// Presents a borderless panel prompting the user to hold a modifier
/// combination. The first key/flags event that includes an allowed modifier is
/// captured; Escape cancels. Calls `onCapture(nil)` if cancelled.
@MainActor
final class SuppressKeyRecorder: NSObject {
    private var window: NSWindow?
    private var monitor: Any?
    private var onCapture: ((SuppressKey?) -> Void)?

    func present(current: SuppressKey, onCapture: @escaping (SuppressKey?) -> Void) {
        self.onCapture = onCapture

        let content = RecorderView(currentDisplay: current.displayString)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Suppress Key"
        window.contentView = content
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Local monitor: only fires while our panel is key, so we don't capture
        // the user's normal typing.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil // swallow while recording
        }
    }

    private func handle(_ event: NSEvent) {
        // Escape cancels.
        if event.type == .keyDown && event.keyCode == 53 {
            finish(with: nil)
            return
        }
        // Capture on key-up of modifiers or a key press that carries an allowed
        // modifier. We accept the first event whose flags include one.
        if let key = SuppressKey.fromRecorded(event.modifierFlags) {
            finish(with: key)
        }
    }

    private func finish(with key: SuppressKey?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.close()
        window = nil
        let callback = onCapture
        onCapture = nil
        callback?(key)
    }
}

/// Static instructions view for the recorder panel.
private final class RecorderView: NSView {
    init(currentDisplay: String) {
        super.init(frame: .zero)

        let title = NSTextField(labelWithString: "Hold a modifier combination")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center

        let hint = NSTextField(labelWithString: "⌃ Control · ⌥ Option · ⌘ Command. Esc to cancel.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center

        let current = NSTextField(labelWithString: "Current: \(currentDisplay)")
        current.font = .systemFont(ofSize: 12)
        current.textColor = .tertiaryLabelColor
        current.alignment = .center

        let stack = NSStackView(views: [title, hint, current])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
