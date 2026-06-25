//  hipApp.swift
//  hip
//  Created by Mike Lucyšyn on 3/30/26.

import SwiftUI
import AppKit

// MARK: - Shared notification names

extension Notification.Name {
    /// Posted when "File → Open" or ⌘O fires from the menu bar.
    static let hipOpenFile    = Notification.Name("hip.openFile")
    /// Posted when "Window → Show Preview Window" fires.
    static let hipShowPreview = Notification.Name("hip.showPreview")
}

// MARK: - App Delegate (Cmd+Q interception)

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = AppViewModel.shared, vm.isProcessing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Processing in Progress"
        alert.informativeText = "A conversion is still running. Quit anyway? The partial output will be deleted."
        alert.addButton(withTitle: "Quit & Delete Output")
        alert.addButton(withTitle: "Keep Running")
        alert.alertStyle = .warning
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            MainActor.assumeIsolated { AppViewModel.shared?.cancelAndCleanup() }
            return .terminateNow
        }
        return .terminateCancel
    }
}

// MARK: - App

@main
struct hipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
