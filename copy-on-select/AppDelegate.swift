//
//  AppDelegate.swift
//  copy-on-select
//
//  Owns the menu-bar item, the enable/disable toggle, the Accessibility
//  permission flow, and the lifecycle of the SelectionWatcher.
//

import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    /// Whether the user has the feature toggled on. Persisted across launches.
    private var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "isEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "isEnabled") }
    }

    /// Polls accessibility status so the menu reflects permission changes the
    /// user makes in System Settings while we're running.
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        applyEnabledState()

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMenuAndState()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SelectionWatcher.shared.stop()
        permissionTimer?.invalidate()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Template image: a black silhouette that macOS auto-tints for
            // light/dark menu bars.
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            image?.accessibilityDescription = "Copy on Select"
            button.image = image
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let granted = isAccessibilityTrusted(prompt: false)

        // Enable / disable toggle.
        let toggleItem = NSMenuItem(
            title: "Copy on Select",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = (isEnabled && granted) ? .on : .off
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Accessibility permission status.
        if granted {
            let ok = NSMenuItem(title: "Accessibility: Granted", action: nil, keyEquivalent: "")
            ok.isEnabled = false
            menu.addItem(ok)
        } else {
            let warn = NSMenuItem(
                title: "Accessibility: Not granted",
                action: nil,
                keyEquivalent: ""
            )
            warn.isEnabled = false
            menu.addItem(warn)

            let grant = NSMenuItem(
                title: "Grant Accessibility Access…",
                action: #selector(requestAccessibility),
                keyEquivalent: ""
            )
            grant.target = self
            menu.addItem(grant)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        applyEnabledState()
        rebuildMenu()
    }

    @objc private func requestAccessibility() {
        // Triggers the system prompt that deep-links to System Settings.
        _ = isAccessibilityTrusted(prompt: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - State

    /// Starts or stops the watcher to match the toggle + permission state.
    private func applyEnabledState() {
        if isEnabled && isAccessibilityTrusted(prompt: false) {
            SelectionWatcher.shared.start()
        } else {
            SelectionWatcher.shared.stop()
        }
    }

    /// Called on a timer to keep the watcher and menu in sync with permission
    /// changes made outside the app.
    private func refreshMenuAndState() {
        let shouldRun = isEnabled && isAccessibilityTrusted(prompt: false)
        if shouldRun != SelectionWatcher.shared.isRunning {
            applyEnabledState()
        }
        rebuildMenu()
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
