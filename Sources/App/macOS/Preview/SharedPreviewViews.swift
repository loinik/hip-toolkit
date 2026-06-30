// SharedPreviewViews.swift — reusable sub-views used across multiple preview files

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Code view (Lua source, JSON text, etc.)

struct CodeView: View {
    let text:       String
    let badge:      String
    let icon:       String
    var exportData: Data?   = nil
    var exportName: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(badge, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let data = exportData, let name = exportName {
                    Button(S.get("preview_export")) {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = name + ".lua"
                        panel.allowedContentTypes  = [UTType(filenameExtension: "lua") ?? .data]
                        NSApp.activate(ignoringOtherApps: true)
                        if panel.runModal() == .OK, let dest = panel.url { try? data.write(to: dest) }
                    }
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }
}

// MARK: - Bytecode view (compiled Lua)

struct BytecodeView: View {
    let bytes:      Int
    var exportData: Data?   = nil
    var exportName: String? = nil
    var sourcePath: String? = nil

    @State private var isDecompiling = false
    @State private var decompiled: String? = nil
    @State private var decompileError: String? = nil

    var body: some View {
        Group {
            if let src = decompiled {
                CodeView(text: src, badge: S.get("preview_decompiled_lua"), icon: "doc.text",
                         exportData: src.data(using: .utf8),
                         exportName: exportName)
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "lock.doc.fill").font(.system(size: 52)).foregroundStyle(.secondary)
                    VStack(spacing: 4) {
                        Text(S.get("bytecode_title")).font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(LocalizedStringKey(S.get("bytecode_hint")))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let err = decompileError {
                        Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    }
                    HStack(spacing: 12) {
                        if let data = exportData, let name = exportName {
                            Button(S.get("bytecode_save")) {
                                let panel = NSSavePanel()
                                panel.nameFieldStringValue = name + ".lua"
                                panel.allowedContentTypes  = [UTType(filenameExtension: "lua") ?? .data]
                                NSApp.activate(ignoringOtherApps: true)
                                if panel.runModal() == .OK, let dest = panel.url { try? data.write(to: dest) }
                            }
                            .buttonStyle(.glass).buttonBorderShape(.capsule)
                        }
                        if sourcePath != nil {
                            Button {
                                runDecompile()
                            } label: {
                                HStack(spacing: 4) {
                                    if isDecompiling {
                                        ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                                        Text(S.get("preview_decompiling"))
                                    } else {
                                        Text(S.get("lua_action_decompile"))
                                        Text("β").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.glass).buttonBorderShape(.capsule)
                            .disabled(isDecompiling)
                        }
                    }
                    Spacer()
                }
                .padding()
            }
        }
    }

    private func runDecompile() {
        guard let path = sourcePath, let data = exportData else { return }
        isDecompiling = true
        decompileError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".lua")
                try data.write(to: tmp)
                let src = try HIPWrapper.decompileLua(atPath: tmp.path)
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run {
                    isDecompiling = false
                    if let s = src as String?, !s.isEmpty { decompiled = s }
                    else { decompileError = S.get("preview_decompile_empty_error") }
                }
            } catch {
                await MainActor.run {
                    isDecompiling = false
                    decompileError = error.localizedDescription
                }
            }
        }
    }
}

#Preview("Code View") {
    CodeView(text: "-- example.lua\nprint(\"hello world\")\n",
             badge: "Lua source", icon: "doc.text")
        .frame(width: 500, height: 300)
}

#Preview("Bytecode View") {
    BytecodeView(bytes: 1024)
        .frame(width: 500, height: 400)
}
