//  hipApp.swift
//  hip
//  Created by Mike Lucyšyn on 3/30/26.

import SwiftUI

// MARK: - Shared notification names

extension Notification.Name {
    /// Posted when "File → Open" or ⌘O fires from the menu bar.
    static let hipOpenFile    = Notification.Name("hip.openFile")
    /// Posted when "Window → Show Preview Window" fires.
    static let hipShowPreview = Notification.Name("hip.showPreview")
}

// MARK: - App

@main
struct hipApp: App {
    var body: some Scene {

        // ── Main converter window ─────────────────────────────────────
        WindowGroup {
            ContentView()
        }
        .handlesExternalEvents(matching: [])
        .commands {

            // ── File menu ──────────────────────────────────────────────
            // Remove the built-in "New Window" item entirely.
            CommandGroup(replacing: .newItem) { }

            // Add "File → Open…" (same action as ⌘O in the toolbar).
            CommandGroup(after: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .hipOpenFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // ── Window menu ────────────────────────────────────────────
            // Append "Show Preview Window" after the standard window commands.
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Show Preview Window") {
                    NotificationCenter.default.post(name: .hipShowPreview, object: nil)
                }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            }
        }

        // ── Preview window (parameterised by URL) ─────────────────────
        WindowGroup(id: "hip-toolkit.preview", for: URL.self) { $url in
            PreviewWindowRootView(url: $url)
                .onOpenURL { url = $0 }
        }
        .defaultSize(width: 720, height: 520)
        .restorationBehavior(.disabled)
    }
}
