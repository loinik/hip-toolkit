// ContentView.swift — main converter window

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main view

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @Environment(\.openWindow) private var openWindow
    @State private var showSupportAlert = false
    @State private var availableUpdate: String?
    @State private var showNoUpdate = false
    @State private var showUpdateFailed = false

    var body: some View {
        VStack(spacing: 10) {
            DropZoneView(vm: vm, openPanel: openPanel, handleDrop: handleDrop)
            SettingsBarView(vm: vm)
            if !vm.results.isEmpty { HistoryPanel(vm: vm) }
        }
        .padding(16)
        .frame(minWidth: 580, minHeight: 420)
        .toolbar { toolbarContent }
        .toolbar(removing: .title)
        .background(WindowTabbingDisabler())
        .background(WindowCloseInterceptor.installer)
        .task {
            if case let .available(v) = await UpdateChecker.check() { availableUpdate = v }
        }
        .alert(S.get("update_title"), isPresented: Binding(
            get: { availableUpdate != nil },
            set: { if !$0 { availableUpdate = nil } }
        )) {
            Button(S.get("update_view")) {
                NSWorkspace.shared.open(UpdateChecker.releasesURL)
                availableUpdate = nil
            }
            Button(S.get("update_later"), role: .cancel) { availableUpdate = nil }
        } message: {
            Text(S.fmt("update_message", availableUpdate ?? "", UpdateChecker.currentVersion))
        }
        .alert(S.get("update_none_title"), isPresented: $showNoUpdate) {
            Button(S.get("update_ok"), role: .cancel) { }
        } message: {
            Text(S.fmt("update_none_message", UpdateChecker.currentVersion))
        }
        .alert(S.get("update_failed_title"), isPresented: $showUpdateFailed) {
            Button(S.get("update_ok"), role: .cancel) { }
        } message: {
            Text(S.get("update_failed_message"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .hipCheckUpdates)) { _ in
            Task {
                switch await UpdateChecker.check() {
                case .available(let v): availableUpdate = v
                case .upToDate:         showNoUpdate = true
                case .failed:           showUpdateFailed = true
                }
            }
        }
        .alert(S.get("alert_cancel_title"), isPresented: $vm.showCancelConfirmation) {
            Button(S.get("alert_cancel_confirm"), role: .destructive) { vm.cancelAndCleanup() }
            Button(S.get("alert_cancel_keep"), role: .cancel) { }
        } message: {
            Text(S.get("alert_cancel_message"))
        }
        .alert(S.get("alert_support_title"), isPresented: $showSupportAlert) {
            Button(S.get("alert_support_kofi")) {
                NSWorkspace.shared.open(URL(string: "https://ko-fi.com/nancydrewhub")!)
            }
            Button(S.get("alert_support_instagram")) {
                NSWorkspace.shared.open(URL(string: "https://instagram.com/nancydrewhub")!)
            }
            Button(S.get("alert_support_close"), role: .cancel) { }
        } message: {
            Text(S.get("alert_support_message"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .hipOpenFile)) { _ in
            openFileForPreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hipOpenURLInPreview)) { notif in
            if let url = notif.object as? URL {
                openWindow(id: "hip-toolkit.preview", value: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hipShowPreview)) { _ in
            openWindow(id: "hip-toolkit.preview", value: URL?.none)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("", selection: $vm.category) {
                ForEach(AppCategory.allCases) { c in Text(c.localizedTitle).tag(c) }
            }
            .pickerStyle(.segmented)
            .disabled(vm.isProcessing)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showSupportAlert = true } label: {
                Label(S.get("toolbar_support"), systemImage: "heart")
            }
            .help(S.get("toolbar_support_help"))
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: openFileForPreview) {
                Label(S.get("toolbar_open"), systemImage: "folder")
            }
            .help(S.get("toolbar_open_help"))
        }
    }

    // MARK: Open for inspection (⌘O)

    private func openFileForPreview() {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.allowsMultipleSelection = true
        panel.message                 = S.get("open_panel_inspect")
        panel.allowedContentTypes     = [
            UTType(filenameExtension: "cif")    ?? .data,
            UTType(filenameExtension: "his")    ?? .data,
            UTType(filenameExtension: "dat")    ?? .data,
            UTType(filenameExtension: "lua")    ?? .data,
            UTType(filenameExtension: "ogg")    ?? .data,
            UTType(filenameExtension: "xsheet") ?? .data,
            .png,
            UTType(filenameExtension: "jpg")    ?? .data,
            UTType(filenameExtension: "jpeg")   ?? .data,
        ]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls {
                RecentFilesModel.shared?.note(url)
                openWindow(id: "hip-toolkit.preview", value: url)
            }
        }
    }

    // MARK: Conversion panel

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories    = vm.mode == .ciftreePack
        panel.canChooseFiles          = vm.mode != .ciftreePack
        panel.allowsMultipleSelection = vm.mode != .ciftreePack && vm.mode != .ciftreeUnpack
        switch vm.mode {
        case .cifEncode:
            panel.allowedContentTypes = [
                .png,
                UTType(filenameExtension: "jpg")    ?? .data,
                UTType(filenameExtension: "jpeg")   ?? .data,
                UTType(filenameExtension: "lua")    ?? .data,
                UTType(filenameExtension: "xsheet") ?? .data,
                .json,
            ]
        case .cifDecode:
            panel.allowedContentTypes = [UTType(filenameExtension: "cif") ?? .data]
        case .ciftreePack:
            panel.allowedContentTypes = []
        case .ciftreeUnpack:
            panel.allowedContentTypes = [UTType(filenameExtension: "dat") ?? .data]
        case .hisEncode:
            panel.allowedContentTypes = [
                UTType(filenameExtension: "wav") ?? .data,
                UTType(filenameExtension: "ogg") ?? .data,
                UTType(filenameExtension: "mp3") ?? .data,
            ]
        case .hisDecode:
            panel.allowedContentTypes = [UTType(filenameExtension: "his") ?? .data]
        }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { vm.processURLs(panel.urls) }
    }

    // MARK: Drop handler

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                guard let d = item as? Data,
                      let u = URL(dataRepresentation: d, relativeTo: nil) else { return }
                urls.append(u)
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            self.vm.autoSwitchMode(for: urls)
            self.vm.processURLs(urls)
        }
        return true
    }
}

// MARK: - Drop zone

struct DropZoneView: View {
    @ObservedObject var vm: AppViewModel
    let openPanel: () -> Void
    let handleDrop: ([NSItemProvider]) -> Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    vm.isDragging ? Color.accentColor.opacity(0.7)
                                  : Color.secondary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .animation(.easeInOut(duration: 0.15), value: vm.isDragging)
            if vm.isProcessing {
                processingView
            } else {
                dropHint
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if !vm.isProcessing { openPanel() } }
        .onDrop(of: [.fileURL], isTargeted: $vm.isDragging) { vm.isProcessing ? false : handleDrop($0) }
    }

    private var processingView: some View {
        VStack(spacing: 14) {
            if let p = vm.progress, p.total > 0 {
                let pct = Int(Double(p.current) / Double(p.total) * 100)
                VStack(spacing: 10) {
                    ProgressView(value: Double(p.current), total: Double(p.total))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                    Text("\(p.current) of \(p.total) · \(pct)%")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                ProgressView(S.get("processing_label")).controlSize(.large)
            }
            Button(S.get("cancel_button")) { vm.requestCancel() }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .font(.subheadline)
        }
    }

    private var dropHint: some View {
        VStack(spacing: 10) {
            Image(systemName: dropIcon)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, value: vm.isDragging)
            Text(dropTitle).font(.headline)
            Text(dropSubtitle)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(chooseLabel, action: openPanel)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding()
    }

    private var chooseLabel: String {
        switch vm.mode {
        case .ciftreePack:   return S.get("choose_folder")
        case .ciftreeUnpack: return S.get("choose_archive")
        default:             return S.get("choose_files")
        }
    }
    private var dropIcon: String {
        switch vm.mode {
        case .cifEncode:     return "arrow.down.doc"
        case .cifDecode:     return "arrow.up.doc"
        case .ciftreePack:   return "archivebox"
        case .ciftreeUnpack: return "archivebox.fill"
        case .hisEncode:     return "waveform.badge.plus"
        case .hisDecode:     return "waveform.badge.minus"
        }
    }
    private var dropTitle: String {
        switch vm.mode {
        case .cifEncode:     return S.get("drop_title_cif_encode")
        case .cifDecode:     return S.get("drop_title_cif_decode")
        case .ciftreePack:   return S.get("drop_title_ciftree_pack")
        case .ciftreeUnpack: return S.get("drop_title_ciftree_unpack")
        case .hisEncode:     return S.get("drop_title_his_encode")
        case .hisDecode:     return S.get("drop_title_his_decode")
        }
    }
    private var dropSubtitle: String {
        switch vm.mode {
        case .cifEncode:     return S.get("drop_subtitle_cif_encode")
        case .cifDecode:     return S.get("drop_subtitle_cif_decode")
        case .ciftreePack:   return S.get("drop_subtitle_ciftree_pack")
        case .ciftreeUnpack: return S.get("drop_subtitle_ciftree_unpack")
        case .hisEncode:     return S.get("drop_subtitle_his_encode")
        case .hisDecode:     return S.get("drop_subtitle_his_decode")
        }
    }
}

// MARK: - Settings bar

struct SettingsBarView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        HStack(spacing: 14) {
            Picker("", selection: $vm.direction) {
                Text(dirForwardLabel).tag(AppDirection.forward)
                Text(dirBackwardLabel).tag(AppDirection.backward)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(vm.isProcessing)

            switch vm.mode {
            case .cifEncode:
                Divider().frame(height: 18)
                Toggle(S.get("toggle_compile_lua"), isOn: $vm.compileLua)
                    .toggleStyle(.checkbox)
                    .help(S.get("tooltip_compile_lua"))
                Divider().frame(height: 18)
                Toggle(S.get("toggle_type4_ovl"), isOn: $vm.useType4PNG)
                    .toggleStyle(.checkbox)
                    .help(S.get("tooltip_type4_ovl"))

            case .ciftreePack:
                Divider().frame(height: 18)
                Toggle(S.get("toggle_compile_lua"), isOn: $vm.compileLua)
                    .toggleStyle(.checkbox)
                    .help(S.get("tooltip_compile_lua"))
                Divider().frame(height: 18)
                Toggle(S.get("toggle_capitalize_names"), isOn: $vm.capitalizeNames)
                    .toggleStyle(.checkbox)
                    .help(S.get("tooltip_capitalize_names"))

            case .cifDecode:
                Divider().frame(height: 18)
                Toggle(isOn: $vm.decompileLua) {
                    HStack(spacing: 4) {
                        Text(S.get("toggle_decompile_lua"))
                        Text("ß").foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .help(S.get("tooltip_decompile_lua"))

            case .ciftreeUnpack:
                Divider().frame(height: 18)
                Toggle(S.get("toggle_extract_cif_contents"), isOn: $vm.extractCifContents)
                    .toggleStyle(.checkbox)
                    .help(S.get("tooltip_extract_cif_contents"))
                Divider().frame(height: 18)
                Toggle(isOn: $vm.decompileLua) {
                    HStack(spacing: 4) {
                        Text(S.get("toggle_decompile_lua"))
                        Text("ß").foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .help(S.get("tooltip_decompile_lua"))

            case .hisDecode:
                Divider().frame(height: 18)
                Text(S.get("his_output_format_label"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Picker("", selection: $vm.hisOutputFormat) {
                    ForEach(HisOutputFormat.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(vm.isProcessing)

            default:
                EmptyView()
            }

            Spacer()
        }
        .padding(.horizontal, 2)
        .animation(.easeInOut(duration: 0.15), value: vm.mode)
    }

    private var dirForwardLabel: String {
        switch vm.category {
        case .cif:     return S.get("dir_file_to_cif")
        case .ciftree: return S.get("dir_pack")
        case .his:     return S.get("dir_file_to_his")
        }
    }
    private var dirBackwardLabel: String {
        switch vm.category {
        case .cif:     return S.get("dir_cif_to_file")
        case .ciftree: return S.get("dir_unpack")
        case .his:     return S.get("dir_his_to_file")
        }
    }
}

// MARK: - History panel

struct HistoryPanel: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(S.get("history_section"))
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Button(S.get("history_clear"), action: vm.clearResults)
                    .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
            }
            .padding(.horizontal, 2)
            GlassEffectContainer {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.results) { r in
                            ResultRow(result: r)
                            if r.id != vm.results.last?.id {
                                Divider().padding(.leading, 48).opacity(0.3)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .glassEffect(in: .rect(cornerRadius: 12))
            .frame(maxHeight: 200)
        }
    }
}

// MARK: - Result row

struct ResultRow: View {
    let result: ConversionResult
    @State private var isExpanded = false

    var body: some View {
        if result.isExpandable {
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView {
                    Text(result.detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 44)
                        .padding(.bottom, 6)
                }
                .frame(maxHeight: 140)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: result.icon)
                        .foregroundStyle(result.tint)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 28, height: 28, alignment: .center)
                    Text(result.title)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        } else {
            HStack(spacing: 12) {
                Image(systemName: result.icon)
                    .foregroundStyle(result.tint)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 28, height: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.system(.body, design: .monospaced)).lineLimit(1)
                    Text(result.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = result.revealURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
    }
}

#Preview {
    ContentView()
}

#Preview("History Panel") {
    HistoryPanel(vm: {
        let vm = AppViewModel()
        vm.results = [
            ConversionResult(icon: "checkmark.circle.fill", tint: .green,
                             title: "image.cif", detail: "512×512 · 42 KB"),
            ConversionResult(icon: "xmark.circle.fill", tint: .red,
                             title: "bad.cif", detail: "Decode error: invalid header"),
            ConversionResult(icon: "exclamationmark.triangle.fill", tint: .yellow,
                             title: "script.lua", detail: "→ .lua  bytecode saved"),
        ]
        return vm
    }())
}

#Preview("Drop Zone") {
    DropZoneView(vm: AppViewModel(), openPanel: {}, handleDrop: { _ in true })
        .frame(width: 540, height: 300)
        .padding(16)
}

#Preview("Settings Bar — CIF Encode") {
    SettingsBarView(vm: AppViewModel())
        .padding()
        .frame(width: 540)
}
