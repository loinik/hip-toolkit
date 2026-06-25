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

    public void AutoSwitchMode(string path)
    {
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
                if (Mode == AppMode.CiftreePack)
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
                        _ => [Fail(Path.GetFileName(path), "Unknown mode")]
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
        if (!path.EndsWith(".ogg", StringComparison.OrdinalIgnoreCase))
            return [Fail(name, "Expected .ogg")];
        try
        {
            var data = HIPInterop.EncodeHIS(path);
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
            return [Fail(name, "Expected .his")];
        try
        {
            var data = HIPInterop.DecodeHIS(path);
            var outPath = Path.ChangeExtension(path, ".ogg");
            File.WriteAllBytes(outPath, data);
            return [Ok(name, $"→ .ogg  {FormatSize(data.Length)}")];
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
