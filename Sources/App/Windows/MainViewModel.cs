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

public record ConversionResult(string Icon, string Title, string Detail, bool IsError);

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

    // ── Processing ───────────────────────────────────────────────────────

    public async Task ProcessFilesAsync(IReadOnlyList<string> paths)
    {
        IsProcessing = true;
        try
        {
            foreach (var path in paths)
            {
                await Task.Run(() =>
                {
                    var results = Mode switch
                    {
                        AppMode.CifEncode     => EncodeCIF(path),
                        AppMode.CifDecode     => DecodeCIF(path),
                        AppMode.CiftreePack   => PackCiftree(path),
                        AppMode.CiftreeUnpack => UnpackCiftree(path),
                        AppMode.HisEncode     => EncodeHIS(path),
                        AppMode.HisDecode     => DecodeHIS(path),
                        _ => [Fail(Path.GetFileName(path), "Unknown mode")]
                    };

                    // Must update ObservableCollection on UI thread
                    foreach (var r in results)
                        _uiQueue.TryEnqueue(() => Results.Insert(0, r));
                });
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
            if (ext is ".xsheet") detail += " · XSheet";

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
                6 => ".xsheet",
                _ => ".bin"
            };

            var outPath = Path.ChangeExtension(path, outExt);
            File.WriteAllBytes(outPath, data);

            var detail = FormatSize(data.Length);
            if (info.IsPNG || info.IsOVL) detail = $"{info.Width}×{info.Height} · {detail}";
            if (info.IsOVL) detail += " · OVL";
            if (info.IsXSheet) detail = $"XSheet · {detail}";

            return [Ok(name, $"→ {outExt}  {detail}")];
        }
        catch (Exception ex) { return [Fail(name, ex.Message)]; }
    }

    // ── Ciftree pack ─────────────────────────────────────────────────────

    private List<ConversionResult> PackCiftree(string folderPath)
    {
        var name = Path.GetFileName(folderPath);
        if (!Directory.Exists(folderPath))
            return [Fail(name, "Expected a folder")];
        try
        {
            var data = HIPInterop.PackFolder(folderPath, CapitalizeNames, CompileLua, UseType4PNG);

            // Save next to the folder with .dat extension
            var outPath = folderPath.TrimEnd(Path.DirectorySeparatorChar) + ".dat";
            File.WriteAllBytes(outPath, data);

            return [Ok(name, $"→ .dat  {FormatSize(data.Length)}")];
        }
        catch (Exception ex) { return [Fail(name, ex.Message)]; }
    }

    // ── Ciftree unpack ───────────────────────────────────────────────────

    private List<ConversionResult> UnpackCiftree(string path)
    {
        var name = Path.GetFileName(path);
        if (!path.EndsWith(".dat", StringComparison.OrdinalIgnoreCase))
            return [Fail(name, "Expected .dat archive")];
        try
        {
            var outDir = Path.ChangeExtension(path, null);
            Directory.CreateDirectory(outDir);
            HIPInterop.UnpackToFolder(path, outDir, ExtractCifContents);

            var count = Directory.GetFiles(outDir, "*", SearchOption.TopDirectoryOnly).Length;
            return [Ok(name, $"→ {count} files extracted to {Path.GetFileName(outDir)}/")];
        }
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
