// LuaPreviewView.swift — standalone .lua file preview

import SwiftUI

struct LuaPreviewView: View {
    let url: URL
    @State private var data:         Data?
    @State private var source:       String?
    @State private var isCompiled    = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let err = errorMessage {
                ContentUnavailableView(S.get("preview_read_error"), systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else if isCompiled, let d = data {
                BytecodeView(bytes: d.count,
                             exportData: d,
                             exportName: url.deletingPathExtension().lastPathComponent,
                             sourcePath: url.path)
            } else if let src = source {
                CodeView(text: src, badge: S.get("preview_lua_source"), icon: "doc.text",
                         exportData: Data(src.utf8),
                         exportName: url.deletingPathExtension().lastPathComponent)
            } else { ProgressView(S.get("preview_reading")) }
        }
        .frame(minWidth: 500, minHeight: 360)
        .task {
            guard let d = try? Data(contentsOf: url) else {
                errorMessage = S.get("preview_cannot_read"); return
            }
            data = d
            isCompiled = d.count >= 4 && d[0] == 0x1B && d[1] == 0x4C
                                       && d[2] == 0x75 && d[3] == 0x61
            if !isCompiled {
                source = String(data: d, encoding: .utf8)
                       ?? String(data: d, encoding: .isoLatin1)
            }
        }
    }
}

#Preview("Lua Source") {
    let src = """
    -- main.lua
    function onEnter(scene)
        scene:setBackground("BG_LOBBY")
        playMusic("theme_main")
    end

    function onExit(scene)
        scene:fadeOut(0.5)
    end
    """
    return CodeView(text: src, badge: "Lua source", icon: "doc.text",
                    exportData: Data(src.utf8), exportName: "main")
        .frame(width: 540, height: 340)
}

#Preview("Lua Bytecode") {
    BytecodeView(bytes: 2048)
        .frame(width: 540, height: 280)
}
