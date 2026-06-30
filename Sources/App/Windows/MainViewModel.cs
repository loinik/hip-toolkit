using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;

namespace HIPToolkit;

public enum AppCategory { CIF, Ciftree, HIS }
public enum AppDirection { Forward, Backward }

public enum AppMode
{
    CifEncode, CifDecode,
    CiftreePack, CiftreeUnpack,
    HisEncode, HisDecode
}

public enum HisOutputFormat { OGG, WAV, MP3 }

public enum LuaCollisionChoice { UseNewName, RenameOriginal, Overwrite, Cancel }

public enum LuaDropAction { Pack, Decompile, Cancel }


public record ConversionResult(string Icon, string Title, string Detail, bool IsError, bool IsExpandable = false, string? RevealPath = null)
{
    public bool HasRevealPath => RevealPath != null;
}

public sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly DispatcherQueue _uiQueue;

    public MainViewModel(DispatcherQueue uiQueue)
    {
        _uiQueue = uiQueue;
    }

    // ── Observable properties ────────────────────────────────────────────

    private AppCategory _category = AppCategory.CIF;
    public AppCategory Category
    {
        get => _category;
        set { _category = value; OnPropertyChanged(); OnPropertyChanged(nameof(Mode)); }
    }

    private AppDirection _direction = AppDirection.Forward;
    public AppDirection Direction
    {
        get => _direction;
        set { _direction = value; OnPropertyChanged(); OnPropertyChanged(nameof(Mode)); }
    }

    private bool _compileLua = true;
    public bool CompileLua
    {
        get => _compileLua;
        set { _compileLua = value; OnPropertyChanged(); }
    }

    private bool _decompileLua;
    public bool DecompileLua
    {
        get => _decompileLua;
        set { _decompileLua = value; OnPropertyChanged(); }
    }

    private bool _extractCifContents = true;
    public bool ExtractCifContents
    {
        get => _extractCifContents;
        set { _extractCifContents = value; OnPropertyChanged(); }
    }

    private bool _capitalizeNames;
    public bool CapitalizeNames
    {
        get => _capitalizeNames;
        set { _capitalizeNames = value; OnPropertyChanged(); }
    }

    private bool _useType4PNG;
    public bool UseType4PNG
    {
        get => _useType4PNG;
        set { _useType4PNG = value; OnPropertyChanged(); }
    }

    private HisOutputFormat _hisOutputFormat = HisOutputFormat.WAV;
    public HisOutputFormat HisOutputFormat
    {
        get => _hisOutputFormat;
        set { _hisOutputFormat = value; OnPropertyChanged(); }
    }

    private bool _isProcessing;
    public bool IsProcessing
    {
        get => _isProcessing;
        set { _isProcessing = value; OnPropertyChanged(); }
    }

    public ObservableCollection<ConversionResult> Results { get; } = new();

    public AppMode Mode => (Category, Direction) switch
    {
        (AppCategory.CIF, AppDirection.Forward)       => AppMode.CifEncode,
        (AppCategory.CIF, AppDirection.Backward)      => AppMode.CifDecode,
        (AppCategory.Ciftree, AppDirection.Forward)   => AppMode.CiftreePack,
        (AppCategory.Ciftree, AppDirection.Backward)  => AppMode.CiftreeUnpack,
        (AppCategory.HIS, AppDirection.Forward)       => AppMode.HisEncode,
        (AppCategory.HIS, AppDirection.Backward)      => AppMode.HisDecode,
        _ => AppMode.CifEncode
    };

    // ── File kind auto-detection (mirrors Swift HIPFileKind) ─────────────

    /// True if the file's first four bytes are the compiled-Lua signature
    /// (ESC 'L' 'u' 'a'). A dropped compiled .lua is content-routed straight
    /// to decompilation regardless of the selected tab — mirroring how a
    /// dropped .dat always unpacks and a dropped folder always packs.
    public static bool IsCompiledLuaFile(string path)
    {
        if (!path.EndsWith(".lua", StringComparison.OrdinalIgnoreCase)) return false;
        try
        {
            using var fs = File.OpenRead(path);
            Span<byte> h = stackalloc byte[4];
            return fs.Read(h) == 4 && h[0] == 0x1B && h[1] == 0x4C && h[2] == 0x75 && h[3] == 0x61;
        }
        catch { return false; }
    }

    /// Set by the View to ask whether a dropped compiled .lua should be packed
    /// into a CIF or decompiled. Returns Decompile if unset.
    public Func<string, Task<LuaDropAction>>? PromptLuaAction;

    /// Set by the View to present the same-folder collision prompt
    /// (originalName, newName) → chosen outcome. Returns Cancel if unset.
    public Func<string, string, Task<LuaCollisionChoice>>? PromptLuaCollision;

    /// Set by the View to show an encoding-picker dialog when auto-detection is ambiguous.
    /// Args: (fileName, rawBytes, candidateNames). Returns chosen encoding name, or null to cancel.
    public Func<string, byte[], List<string>, Task<string?>>? PromptEncoding;

    public void AutoSwitchMode(string path)
    {
        // Compiled .lua is content-routed to decompilation regardless of the
        // tab, so don't flip the segmented control for it.
        if (IsCompiledLuaFile(path)) return;

        var ext = Path.GetExtension(path).ToLowerInvariant();
        bool isDir = Directory.Exists(path);

        (AppCategory cat, AppDirection dir)? suggestion = ext switch
        {
            ".cif"  => (AppCategory.CIF, AppDirection.Backward),
            ".his"  => (AppCategory.HIS, AppDirection.Backward),
            ".dat"  => (AppCategory.Ciftree, AppDirection.Backward),
            ".lua"  => (AppCategory.CIF, AppDirection.Forward),
            ".png"  => (AppCategory.CIF, AppDirection.Forward),
            ".jpg"  => (AppCategory.CIF, AppDirection.Forward),
            ".jpeg" => (AppCategory.CIF, AppDirection.Forward),
            ".ogg"  => (AppCategory.HIS, AppDirection.Forward),
            ".wav"  => (AppCategory.HIS, AppDirection.Forward),
            ".mp3"  => (AppCategory.HIS, AppDirection.Forward),
            ".xsheet" => (AppCategory.CIF, AppDirection.Forward),
            ".json" => (AppCategory.CIF, AppDirection.Forward),
            _ when isDir => (AppCategory.Ciftree, AppDirection.Forward),
            _ => null
        };

        if (suggestion is var (c, d))
        {
            Category = c;
            Direction = d;
        }
    }

    // ── Cancellation ─────────────────────────────────────────────────────

    private CancellationTokenSource? _cts;
    private string? _pendingOutputPath;

    public void RequestCancellation()
    {
        _cts?.Cancel();
        if (_pendingOutputPath != null)
        {
            var path = _pendingOutputPath;
            _pendingOutputPath = null;
            Task.Run(() =>
            {
                try
                {
                    if (File.Exists(path)) File.Delete(path);
                    else if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
                }
                catch { /* best-effort cleanup */ }
            });
        }
    }

    // ── Processing ───────────────────────────────────────────────────────

    public async Task ProcessFilesAsync(IReadOnlyList<string> paths, Action<int, int>? onProgress = null)
    {
        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        IsProcessing = true;
        try
        {
            foreach (var path in paths)
            {
                if (token.IsCancellationRequested) break;
                List<ConversionResult> results;
                if (IsCompiledLuaFile(path))
                    results = await HandleDroppedCompiledLuaAsync(path);
                else if (Mode == AppMode.CiftreePack)
                    results = await PackCiftreeAsync(path, onProgress, token);
                else if (Mode == AppMode.CiftreeUnpack)
                    results = await UnpackCiftreeAsync(path, onProgress, token);
                else
                    results = await Task.Run(() => Mode switch
                    {
                        AppMode.CifEncode => EncodeCIF(path),
                        AppMode.CifDecode => DecodeCIF(path),
                        AppMode.HisEncode => EncodeHIS(path),
                        AppMode.HisDecode => DecodeHIS(path),
                        _ => [Fail(Path.GetFileName(path), S.Get("error_unknown_mode"))]
                    }, token);

                foreach (var r in results)
                    _uiQueue.TryEnqueue(() => Results.Insert(0, r));
            }
        }
        finally
        {
            IsProcessing = false;
        }
    }

    public void ClearResults() => Results.Clear();

    // ── Drop of a compiled .lua ──────────────────────────────────────────────
    //
    //  First asks whether to pack the compiled bytecode into a CIF or decompile
    //  it. For decompilation, the original file is only touched AFTER
    //  decompilation has fully succeeded, immediately before writing the new
    //  file — so a failed decompile can never lose the original. On a
    //  same-folder name collision a second dialog offers three outcomes.
    private async Task<List<ConversionResult>> HandleDroppedCompiledLuaAsync(string path)
    {
        var name = Path.GetFileName(path);
        var action = PromptLuaAction is { } ask ? await ask(name) : LuaDropAction.Decompile;
        return action switch
        {
            LuaDropAction.Cancel => [Warn(name, S.Get("lua_result_not_saved"))],
            LuaDropAction.Pack   => EncodeCIF(path),
            _                    => [await DecompileDroppedLuaAsync(path)],
        };
    }

    private async Task<ConversionResult> DecompileDroppedLuaAsync(string path)
    {
        var name = Path.GetFileName(path);

        // 1. Decompile to raw single-byte bytes (no filesystem writes yet).
        byte[] rawBytes;
        try { rawBytes = await Task.Run(() => HIPInterop.DecompileLuaRaw(path)); }
        catch (Exception ex) { return Fail(name, S.Fmt("lua_result_decompile_failed", ex.Message)); }

        // 2. Detect encoding.
        var (encName, decoded, candidates) = HIPInterop.DetectSingleByteEncoding(rawBytes);

        // 3. If ambiguous, ask the user.
        if (decoded == null && candidates?.Count > 0)
        {
            var picked = PromptEncoding != null
                ? await PromptEncoding(name, rawBytes, candidates)
                : candidates[0];
            if (picked == null) return Warn(name, S.Get("lua_result_not_saved"));
            encName = picked;
            decoded = HIPInterop.EncodingFromName(encName)?.GetString(rawBytes) ?? "";
        }

        if (string.IsNullOrEmpty(decoded))
            return Fail(name, S.Get("lua_result_decompile_empty"));

        // 4. Prepend encoding comment so the pack direction knows the target encoding.
        var comment = encName == "utf-8" ? "" : $"-- @encoding: {encName}\n";
        var source  = comment + decoded;

        // 5. Decide where to write.
        var dir     = Path.GetDirectoryName(path) ?? ".";
        var baseN   = Path.GetFileNameWithoutExtension(path);
        var newPath = UniquePath(dir, $"{baseN} (decompiled)", ".lua");

        var choice = PromptLuaCollision is { } prompt
            ? await prompt(name, Path.GetFileName(newPath))
            : LuaCollisionChoice.UseNewName;

        try
        {
            switch (choice)
            {
                case LuaCollisionChoice.Cancel:
                    return Warn(name, S.Get("lua_result_not_saved"));
                case LuaCollisionChoice.UseNewName:
                    await File.WriteAllTextAsync(newPath, source, System.Text.Encoding.UTF8);
                    return Ok(name, S.Fmt("lua_result_new_name", Path.GetFileName(newPath)));
                case LuaCollisionChoice.RenameOriginal:
                    var renamed = UniquePath(dir, $"{baseN} (compiled)", ".lua");
                    File.Move(path, renamed);
                    await File.WriteAllTextAsync(path, source, System.Text.Encoding.UTF8);
                    return Ok(name, S.Fmt("lua_result_renamed", Path.GetFileName(renamed)));
                case LuaCollisionChoice.Overwrite:
                default:
                    await File.WriteAllTextAsync(path, source, System.Text.Encoding.UTF8);
                    return Ok(name, S.Get("lua_result_overwritten"));
            }
        }
        catch (Exception ex) { return Fail(name, S.Fmt("lua_result_save_failed", ex.Message)); }
    }

    // First free "<base><ext>", "<base> 2<ext>", … in dir.
    private static string UniquePath(string dir, string baseName, string ext)
    {
        var first = Path.Combine(dir, baseName + ext);
        if (!File.Exists(first)) return first;
        for (int n = 2; ; n++)
        {
            var p = Path.Combine(dir, $"{baseName} {n}{ext}");
            if (!File.Exists(p)) return p;
        }
    }

    // ── CIF encode ───────────────────────────────────────────────────────

    private List<ConversionResult> EncodeCIF(string path)
    {
        var name = Path.GetFileName(path);
        var ext = Path.GetExtension(path).ToLowerInvariant();
        try
        {
            byte[] data;
            switch (ext)
            {
                case ".png" or ".jpg" or ".jpeg":
                    uint cifType = UseType4PNG ? 4u : 2u;
                    data = HIPInterop.EncodePNG(path, cifType);
                    break;
                case ".lua":
                    data = HIPInterop.EncodeLua(path, CompileLua);
                    break;
                case ".xsheet":
                    data = HIPInterop.EncodeXSheet(path);
                    break;
                case ".json":
                {
                    var body = HIPInterop.XSheetJsonToBody(File.ReadAllText(path));
                    if (body == null) return [Fail(name, "Not a valid XSheet JSON")];
                    var tmpPath = Path.ChangeExtension(path, ".xsheet");
                    File.WriteAllBytes(tmpPath, body);
                    try { data = HIPInterop.EncodeXSheet(tmpPath); }
                    finally { try { File.Delete(tmpPath); } catch { } }
                    break;
                }
                default:
                    return [Fail(name, $"Unsupported: {ext}")];
            }

            var outPath = Path.ChangeExtension(path, ".cif");
            File.WriteAllBytes(outPath, data);

            var detail = FormatSize(data.Length);
            if (ext is ".png" or ".jpg" or ".jpeg")
            {
                try
                {
                    var hdr = HIPInterop.ReadHeader(path);
                    detail = $"{hdr.Width}×{hdr.Height} · {detail}";
                }
                catch { /* header read optional */ }
                if (UseType4PNG) detail += " · type 4 OVL";
            }
            if (ext == ".lua")
            {
                detail += HIPInterop.IsCompiledLua(path) ? " · pre-compiled" : " · source";
            }
            if (ext is ".xsheet" or ".json") detail += " · XSheet";

            return [Ok(name, detail)];
        }
        catch (Exception ex) { return [Fail(name, ex.Message)]; }
    }

    // ── CIF decode ───────────────────────────────────────────────────────

    private List<ConversionResult> DecodeCIF(string path)
    {
        var name = Path.GetFileName(path);
        if (!path.EndsWith(".cif", StringComparison.OrdinalIgnoreCase))
            return [Fail(name, "Expected .cif")];
        try
        {
            var info = HIPInterop.ReadHeader(path);
            var data = HIPInterop.DecodeCIF(path);

            var outExt = info.Type switch
            {
                2 or 4 => ".png",
                3 => ".lua",
                6 => ".json",
                _ => ".bin"
            };

            var outPath = Path.ChangeExtension(path, outExt);

            // ── Lua ──
            if (info.IsLua)
            {
                File.WriteAllBytes(outPath, data);
                bool isCompiled = data.Length >= 4
                    && data[0] == 0x1B && data[1] == 0x4C
                    && data[2] == 0x75 && data[3] == 0x61;

                if (!isCompiled)
                    return [Ok(name, $"→ .lua  {FormatSize(data.Length)} · source")];

                if (!DecompileLua)
                    return [Ok(name, $"→ .lua  {FormatSize(data.Length)} · bytecode")];

                try
                {
                    var source = HIPInterop.DecompileLua(outPath);
                    if (string.IsNullOrEmpty(source))
                        return [Warn(name, $"→ .lua  {FormatSize(data.Length)} · bytecode saved — decompilation failed: empty output")];
                    File.WriteAllText(outPath, source, System.Text.Encoding.UTF8);
                    return [Ok(name, $"→ .lua  {FormatSize(source.Length)} · decompiled")];
                }
                catch (Exception ex)
                {
                    return [Warn(name, $"→ .lua  {FormatSize(data.Length)} · bytecode saved — {ex.Message}")];
                }
            }

            // ── XSheet → JSON ──
            if (info.IsXSheet)
            {
                var json = HIPInterop.XSheetBodyToJson(data);
                File.WriteAllText(outPath, json, System.Text.Encoding.UTF8);
                return [Ok(name, $"→ .json  {FormatSize(json.Length)} · XSheet")];
            }

            // ── PNG / OVL / other ──
            File.WriteAllBytes(outPath, data);
            var detail = FormatSize(data.Length);
            if (info.IsPNG || info.IsOVL) detail = $"{info.Width}×{info.Height} · {detail}";
            if (info.IsOVL) detail += " · OVL";
            return [Ok(name, $"→ {outExt}  {detail}")];
        }
        catch (Exception ex) { return [Fail(name, ex.Message)]; }
    }

    // Called by MainWindow to provide an alternate save path when access is denied.
    // Set before calling ProcessFilesAsync. Returns null → user cancelled.
    public Func<string, Task<string?>>? RequestAlternateSavePath { get; set; }

    // ── Ciftree pack ─────────────────────────────────────────────────────

    private async Task<List<ConversionResult>> PackCiftreeAsync(string folderPath, Action<int, int>? onProgress = null,
                                                                  CancellationToken token = default)
    {
        var name = Path.GetFileName(folderPath);
        if (!Directory.Exists(folderPath))
            return [Fail(name, "Expected a folder")];
        try
        {
            // Pack on background thread; progress callback already dispatches to UI via DispatcherQueue
            var data = await Task.Run(() =>
            {
                return HIPInterop.PackFolder(folderPath, CapitalizeNames, CompileLua, UseType4PNG,
                    (cur, tot) => { if (!token.IsCancellationRequested) onProgress?.Invoke(cur, tot); });
            }, token);

            if (token.IsCancellationRequested) return [];

            var outPath = folderPath.TrimEnd(Path.DirectorySeparatorChar) + ".dat";
            _pendingOutputPath = outPath;

            try
            {
                File.WriteAllBytes(outPath, data);
            }
            catch (UnauthorizedAccessException)
            {
                var alt = RequestAlternateSavePath != null
                    ? await RequestAlternateSavePath(outPath)
                    : null;
                if (alt == null) return [Fail(name, "Access denied — save cancelled")];
                _pendingOutputPath = alt;
                File.WriteAllBytes(alt, data);
                outPath = alt;
            }

            _pendingOutputPath = null;
            var fileCount = Directory.GetFiles(folderPath, "*", SearchOption.AllDirectories).Length;
            var outName = Path.GetFileName(outPath);
            return [new ConversionResult("", outName, $"{fileCount} files · {FormatSize(data.Length)}", false, RevealPath: outPath)];
        }
        catch (OperationCanceledException) { return []; }
        catch (Exception ex) { return [Fail(name, ex.Message)]; }
    }

    // ── Ciftree unpack ───────────────────────────────────────────────────

    private async Task<List<ConversionResult>> UnpackCiftreeAsync(string path, Action<int, int>? onProgress = null,
                                                                    CancellationToken token = default)
    {
        var name = Path.GetFileName(path);
        if (!path.EndsWith(".dat", StringComparison.OrdinalIgnoreCase))
            return [Fail(name, "Expected .dat archive")];
        try
        {
            var outDir = Path.ChangeExtension(path, null);

            try { Directory.CreateDirectory(outDir); }
            catch (UnauthorizedAccessException)
            {
                var alt = RequestAlternateSavePath != null
                    ? await RequestAlternateSavePath(outDir)
                    : null;
                if (alt == null) return [Fail(name, "Access denied — save cancelled")];
                outDir = alt;
                Directory.CreateDirectory(outDir);
            }

            _pendingOutputPath = outDir;
            bool decompileLua = DecompileLua, extractContents = ExtractCifContents;
            var taskResult = await Task.Run(() =>
            {
                HIPInterop.UnpackToFolder(path, outDir, extractContents,
                    (cur, tot) => { if (!token.IsCancellationRequested) onProgress?.Invoke(cur, tot); });
                if (token.IsCancellationRequested) return [];

                var files = Directory.GetFiles(outDir, "*", SearchOption.TopDirectoryOnly);
                var results = new List<ConversionResult>
                {
                    Ok(name, $"→ {files.Length} files extracted to {Path.GetFileName(outDir)}/")
                };

                if (extractContents)
                {
                    foreach (var file in files)
                    {
                        if (!file.EndsWith(".xsheet", StringComparison.OrdinalIgnoreCase)) continue;
                        try
                        {
                            var json = HIPInterop.XSheetBodyToJson(File.ReadAllBytes(file));
                            var jsonPath = Path.ChangeExtension(file, ".json");
                            File.WriteAllText(jsonPath, json, System.Text.Encoding.UTF8);
                            File.Delete(file);
                        }
                        catch { /* leave .xsheet as-is on error */ }
                    }
                    // Refresh file list after xsheet→json conversion
                    files = Directory.GetFiles(outDir, "*", SearchOption.TopDirectoryOnly);
                    results[0] = Ok(name, $"→ {files.Length} files extracted to {Path.GetFileName(outDir)}/");
                }

                if (decompileLua && extractContents)
                {
                    var failedDecompile = new List<string>();
                    foreach (var file in files)
                    {
                        if (!file.EndsWith(".lua", StringComparison.OrdinalIgnoreCase)) continue;
                        var bytes = File.ReadAllBytes(file);
                        if (bytes.Length < 4 || bytes[0] != 0x1B || bytes[1] != 0x4C
                            || bytes[2] != 0x75 || bytes[3] != 0x61) continue;
                        var fname = Path.GetFileName(file);
                        System.Diagnostics.Debug.WriteLine($"[luadec] → {fname}");
                        try
                        {
                            var source = HIPInterop.DecompileLua(file);
                            if (!string.IsNullOrEmpty(source))
                            {
                                File.WriteAllText(file, source, System.Text.Encoding.UTF8);
                                System.Diagnostics.Debug.WriteLine($"[luadec] ✓ {fname}");
                                results.Add(Ok(fname, "decompiled"));
                            }
                            else
                            {
                                System.Diagnostics.Debug.WriteLine($"[luadec] ✗ {fname}: empty output");
                                failedDecompile.Add(fname);
                            }
                        }
                        catch (Exception ex)
                        {
                            System.Diagnostics.Debug.WriteLine($"[luadec] ✗ {fname}: {ex.Message}");
                            failedDecompile.Add(fname);
                        }
                    }
                    if (failedDecompile.Count > 0)
                    {
                        results.Insert(1, Warn(
                            $"Decompilation failed for {failedDecompile.Count} file(s) — saved as bytecode",
                            string.Join("\n", failedDecompile),
                            expandable: true));
                    }
                }

                return results;
            }, token);
            _pendingOutputPath = null;
            return taskResult;
        }
        catch (OperationCanceledException) { return []; }
        catch (Exception ex) { return [Fail(name, ex.Message)]; }
    }

    // ── HIS encode ───────────────────────────────────────────────────────

    private List<ConversionResult> EncodeHIS(string path)
    {
        var name = Path.GetFileName(path);
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext is not (".ogg" or ".wav" or ".mp3"))
            return [Fail(name, S.Get("error_expected_audio"))];
        try
        {
            var data = HIPInterop.EncodeHISFromAudio(path);
            var outPath = Path.ChangeExtension(path, ".his");
            File.WriteAllBytes(outPath, data);
            return [Ok(name, $"→ .his  {FormatSize(data.Length)}")];
        }
        catch (Exception ex) { return [Fail(name, ex.Message)]; }
    }

    // ── HIS decode ───────────────────────────────────────────────────────

    private List<ConversionResult> DecodeHIS(string path)
    {
        var name = Path.GetFileName(path);
        if (!path.EndsWith(".his", StringComparison.OrdinalIgnoreCase))
            return [Fail(name, S.Get("error_expected_his"))];
        try
        {
            var fmtExt = HisOutputFormat switch {
                HisOutputFormat.WAV => "wav",
                HisOutputFormat.MP3 => "mp3",
                _                  => "ogg"
            };
            var outData = HIPInterop.DecodeHISToFormat(path, fmtExt);
            var outPath = Path.ChangeExtension(path, "." + fmtExt);
            File.WriteAllBytes(outPath, outData);
            return [Ok(name, $"→ .{fmtExt}  {FormatSize(outData.Length)}")];
        }
        catch (Exception ex) { return [Fail(name, ex.Message)]; }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    private static ConversionResult Ok(string title, string detail) =>
        new("\uE73E", title, detail, false);      // ✓ checkmark glyph

    private static ConversionResult Warn(string title, string detail, bool expandable = false) =>
        new("\uE7BA", title, detail, false, expandable);   // ⚠ warning glyph
    private static ConversionResult Fail(string title, string detail) =>
        new("\uEA39", title, detail, true);        // ✗ error glyph

    private static string FormatSize(long bytes) => bytes switch
    {
        < 1024       => $"{bytes} B",
        < 1048576    => $"{bytes / 1024.0:F1} KB",
        < 1073741824 => $"{bytes / 1048576.0:F1} MB",
        _            => $"{bytes / 1073741824.0:F2} GB"
    };

    // ── INotifyPropertyChanged ───────────────────────────────────────────

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
