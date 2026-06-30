//  hipApp.swift
//  hip — HeR Interactive asset converter + inspector

import SwiftUI
import AppKit
import Combine

// MARK: - Shared notification names

extension Notification.Name {
    static let hipOpenFile       = Notification.Name("hip.openFile")
    static let hipShowPreview    = Notification.Name("hip.showPreview")
    static let hipCheckUpdates   = Notification.Name("hip.checkUpdates")
    static let hipDeselectAll    = Notification.Name("hip.deselectAll")
    static let hipOpenURLInPreview = Notification.Name("hip.openURLInPreview")
}

// MARK: - Recent files model

final class RecentFilesModel: ObservableObject {
    static weak var shared: RecentFilesModel?

    @Published private(set) var urls: [URL] = NSDocumentController.shared.recentDocumentURLs

    init() { RecentFilesModel.shared = self }

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        urls = NSDocumentController.shared.recentDocumentURLs
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        urls = []
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = AppViewModel.shared, vm.isProcessing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = S.get("alert_quit_title")
        alert.informativeText = S.get("alert_quit_message")
        alert.addButton(withTitle: S.get("alert_quit_confirm"))
        alert.addButton(withTitle: S.get("alert_quit_keep"))
        alert.alertStyle = .warning
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            MainActor.assumeIsolated { AppViewModel.shared?.cancelAndCleanup() }
            return .terminateNow
        }
        return .terminateCancel
    }

    /// Handles Dock drops and OS-initiated opens.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            RecentFilesModel.shared?.note(url)
            NotificationCenter.default.post(name: .hipOpenURLInPreview, object: url)
        }
    }
}

// MARK: - App

@main
struct hipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var recentFiles = RecentFilesModel()

    var body: some Scene {

        // ── Main converter window ─────────────────────────────────────
        WindowGroup {
            ContentView()
        }
        .handlesExternalEvents(matching: [])
        .commands {

            // ── App menu ───────────────────────────────────────────────
            CommandGroup(after: .appInfo) {
                Button(S.get("menu_check_updates")) {
                    NotificationCenter.default.post(name: .hipCheckUpdates, object: nil)
                }
            }

            // ── File menu ──────────────────────────────────────────────
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .hipOpenFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    ForEach(recentFiles.urls, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            recentFiles.note(url)
                            NotificationCenter.default.post(name: .hipOpenURLInPreview, object: url)
                        }
                        .help(url.path)
                    }
                    if !recentFiles.urls.isEmpty { Divider() }
                    Button("Clear Menu") { recentFiles.clear() }
                        .disabled(recentFiles.urls.isEmpty)
                }
                .disabled(recentFiles.urls.isEmpty)
            }

            // ── Edit menu ──────────────────────────────────────────────
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Deselect All") {
                    NotificationCenter.default.post(name: .hipDeselectAll, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            // ── Window menu ────────────────────────────────────────────
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
