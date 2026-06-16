//
//  copy_on_selectApp.swift
//  copy-on-select
//
//  Created by Lasse Haslund on 16/06/2026.
//

import SwiftUI

@main
struct copy_on_selectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No window scene: this is a background menu-bar agent (LSUIElement).
        // The menu bar item and all behavior live in AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
