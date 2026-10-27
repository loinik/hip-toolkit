using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace HIPToolkit;

/// <summary>
/// P/Invoke wrapper around the bitmap font generator in HIP.Bridge.dll
/// (Sources/Core/BitmapFontGenerator). Options travel as JSON, the result
/// stays native behind a handle (<see cref="FontGenResult"/>).
/// </summary>
internal static class FontGenInterop
{
    private const string DllName = "HIP.Bridge";

    [DllImport(DllName, EntryPoint = "HIP_Free")]
    private static extern void Free(nint ptr);

    [DllImport(DllName, EntryPoint = "HIP_GetLastError")]
    private static extern nint GetLastErrorPtr();

    [DllImport(DllName, EntryPoint = "HIP_FontGenGenerate")]
    private static extern int GenerateRaw([MarshalAs(UnmanagedType.LPUTF8Str)] string optionsJson, out nint handle);

    [DllImport(DllName, EntryPoint = "HIP_FontGenInfo")]
    private static extern int InfoRaw(nint handle, out nint json);

    [DllImport(DllName, EntryPoint = "HIP_FontGenPNG")]
    private static extern int PNGRaw(nint handle, int style, out nint data, out uint size);

    [DllImport(DllName, EntryPoint = "HIP_FontGenSample")]
    private static extern int SampleRaw(nint handle, int style, [MarshalAs(UnmanagedType.LPUTF8Str)] string text,
                                        int maxWidth, int scale, out nint rgba, out uint width, out uint height);

    [DllImport(DllName, EntryPoint = "HIP_FontGenFree")]
    internal static extern void FreeHandle(nint handle);

    [DllImport(DllName, EntryPoint = "HIP_FontGenCharsets")]
    private static extern int CharsetsRaw(out nint json);

    [DllImport(DllName, EntryPoint = "HIP_FontGenPresets")]
    private static extern int PresetsRaw(out nint json);

    [DllImport(DllName, EntryPoint = "HIP_FontGenListInstalled")]
    private static extern int ListInstalledRaw(out nint json);

    private static void ThrowIfFailed(int result)
    {
        if (result != 0)
            throw new InvalidOperationException(Marshal.PtrToStringUTF8(GetLastErrorPtr()) ?? "HIP native error");
    }

    private static string TakeString(nint ptr)
    {
        var s = Marshal.PtrToStringUTF8(ptr) ?? "";
        Free(ptr);
        return s;
    }

    private static byte[] TakeBytes(nint ptr, int size)
    {
        var buf = new byte[size];
        Marshal.Copy(ptr, buf, 0, size);
        Free(ptr);
        return buf;
    }

    // ── Public API ───────────────────────────────────────────────────────

    public record Charset(string Id, string Title);
    public record Preset(string Name, string Family, int PixelSize);
    public record InstalledFace(string Family, string Style, string Path, int FaceIndex,
                                bool Bold, bool Italic, int Weight, int Width);

    public static List<Charset> Charsets()
    {
        ThrowIfFailed(CharsetsRaw(out var p));
        return JsonNode.Parse(TakeString(p))!.AsArray()
            .Select(n => new Charset((string)n!["id"]!, (string)n["title"]!)).ToList();
    }

    public static List<Preset> Presets()
    {
        ThrowIfFailed(PresetsRaw(out var p));
        return JsonNode.Parse(TakeString(p))!.AsArray()
            .Select(n => new Preset((string)n!["name"]!, (string)n["family"]!, (int)n["pixelSize"]!)).ToList();
    }

    public static List<InstalledFace> ListInstalled()
    {
        ThrowIfFailed(ListInstalledRaw(out var p));
        return JsonNode.Parse(TakeString(p))!.AsArray()
            .Select(n => new InstalledFace((string)n!["family"]!, (string)n["style"]!, (string)n["path"]!,
                                           (int)n["faceIndex"]!, (bool)n["bold"]!, (bool)n["italic"]!,
                                           (int)n["weight"]!, (int)n["width"]!)).ToList();
    }

    public static FontGenResult Generate(JsonObject options)
    {
        ThrowIfFailed(GenerateRaw(options.ToJsonString(), out var h));
        return new FontGenResult(h);
    }

    // ── Result ───────────────────────────────────────────────────────────

    public record StyleInfo(bool Present, string OvlName, int Width, int Height, int GlyphCount,
                            int LineHeight, int EmSize, string Missing);

    public sealed class FontGenResult : IDisposable
    {
        private nint _handle;
        public string Lua { get; }
        public IReadOnlyList<StyleInfo> Styles { get; }

        internal FontGenResult(nint handle)
        {
            _handle = handle;
            ThrowIfFailed(InfoRaw(handle, out var p));
            using var doc = JsonDocument.Parse(TakeString(p));
            Lua = doc.RootElement.GetProperty("lua").GetString() ?? "";
            Styles = doc.RootElement.GetProperty("styles").EnumerateArray().Select(s => new StyleInfo(
                s.GetProperty("present").GetBoolean(), s.GetProperty("ovlName").GetString() ?? "",
                s.GetProperty("width").GetInt32(), s.GetProperty("height").GetInt32(),
                s.GetProperty("glyphCount").GetInt32(), s.GetProperty("lineHeight").GetInt32(),
                s.GetProperty("emSize").GetInt32(), s.GetProperty("missing").GetString() ?? "")).ToList();
        }

        public byte[] Png(int style)
        {
            ThrowIfFailed(PNGRaw(_handle, style, out var p, out var size));
            return TakeBytes(p, (int)size);
        }

        /// <summary>Straight RGBA, white text on transparent.</summary>
        public (byte[] Rgba, int Width, int Height) Sample(int style, string text, int maxWidth, int scale)
        {
            ThrowIfFailed(SampleRaw(_handle, style, text, maxWidth, scale, out var p, out var w, out var h));
            return (TakeBytes(p, (int)(w * h * 4)), (int)w, (int)h);
        }

        public void Dispose()
        {
            if (_handle != 0) { FreeHandle(_handle); _handle = 0; }
        }
    }
}
