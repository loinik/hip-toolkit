// WindowHooks.swift — NSView helpers that tweak window behaviour

import SwiftUI
import AppKit

// MARK: - Window Tabbing Disabler

struct WindowTabbingDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> _TabbingDisablerView { _TabbingDisablerView() }
    func updateNSView(_ v: _TabbingDisablerView, context: Context) {}

    final class _TabbingDisablerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.tabbingMode = .disallowed
        }
    }
}

// MARK: - Window close interception

final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    static let shared = WindowCloseInterceptor()

    static var installer: some View { _Installer() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let vm = AppViewModel.shared, vm.isProcessing else { return true }
        let alert = NSAlert()
        alert.messageText = S.get("alert_close_title")
        alert.informativeText = S.get("alert_close_message")
        alert.addButton(withTitle: S.get("alert_close_confirm"))
        alert.addButton(withTitle: S.get("alert_close_keep"))
        alert.alertStyle = .warning
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            MainActor.assumeIsolated { AppViewModel.shared?.cancelAndCleanup() }
            return true
        }
        return false
    }

    private struct _Installer: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let v = NSView()
            DispatchQueue.main.async {
                v.window?.delegate = WindowCloseInterceptor.shared
            }
            return v
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
