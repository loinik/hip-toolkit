using System.Diagnostics;
using System.Runtime.InteropServices;

namespace HIPToolkit;

/// <summary>
/// P/Invoke wrapper around HIP.Bridge.dll (native C API).
/// </summary>
internal static class HIPInterop
{
    private const string DllName = "HIP.Bridge";

    // ── Raw imports ──────────────────────────────────────────────────────

    [DllImport(DllName, EntryPoint = "HIP_Free")]
    private static extern void Free(nint ptr);

    [DllImport(DllName, EntryPoint = "HIP_GetLastError")]
    private static extern nint GetLastErrorPtr();

    [DllImport(DllName, EntryPoint = "HIP_ReadCIFHeader")]
    private static extern int ReadCIFHeader(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        out CIFHeaderRaw header);

    [DllImport(DllName, EntryPoint = "HIP_IsCompiledLua")]
    private static extern int IsCompiledLuaRaw([MarshalAs(UnmanagedType.LPUTF8Str)] string path);

    [DllImport(DllName, EntryPoint = "HIP_EncodePNG")]
    private static extern int EncodePNGRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        uint cifType,
        out nint data,
        out uint size);

    [DllImport(DllName, EntryPoint = "HIP_EncodeLua")]
    private static extern int EncodeLuaRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        int compileLua,
        out nint data,
        out uint size);

    [DllImport(DllName, EntryPoint = "HIP_EncodeXSheet")]
    private static extern int EncodeXSheetRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        out nint data,
        out uint size);

    [DllImport(DllName, EntryPoint = "HIP_DecodeCIF")]
    private static extern int DecodeCIFRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        out nint data,
        out uint size);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void ProgressCallback(int current, int total);

    [DllImport(DllName, EntryPoint = "HIP_PackFolder")]
    private static extern int PackFolderRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string folderPath,
        uint flags,
        out nint data,
        out uint size,
        ProgressCallback? progress);

    [DllImport(DllName, EntryPoint = "HIP_UnpackToFolder")]
    private static extern int UnpackToFolderRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string datPath,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string outDir,
        int extractContents,
        ProgressCallback? progress);

    [DllImport(DllName, EntryPoint = "HIP_CiftreeEntryCount")]
    private static extern int CiftreeEntryCountRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string datPath,
        out uint count);

    [DllImport(DllName, EntryPoint = "HIP_CiftreeEntryInfo")]
    private static extern int CiftreeEntryInfoRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string datPath,
        uint index,
        [Out] byte[] outName,
        uint nameSize,
        out uint outCIFSize,
        out uint outCIFType);

    [DllImport(DllName, EntryPoint = "HIP_EncodeHIS")]
    private static extern int EncodeHISRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string oggPath,
        out nint data,
        out uint size);

    [DllImport(DllName, EntryPoint = "HIP_DecodeHIS")]
    private static extern int DecodeHISRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string hisPath,
        out nint data,
        out uint size);

    [DllImport(DllName, EntryPoint = "HIP_EncodeHISFromAudio")]
    private static extern int EncodeHISFromAudioRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string audioPath,
        out nint data,
        out uint size);

    [DllImport(DllName, EntryPoint = "HIP_DecodeHISToFormat")]
    private static extern int DecodeHISToFormatRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string hisPath,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string format,
        out nint data,
        out uint size);

    [DllImport(DllName, EntryPoint = "HIP_XSheetBodyToJson")]
    private static extern int XSheetBodyToJsonRaw(
        [In] byte[] body, uint bodyLen,
        out nint outJson, out uint outJsonLen);

    [DllImport(DllName, EntryPoint = "HIP_XSheetJsonToBody")]
    private static extern int XSheetJsonToBodyRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string json,
        out nint outBody, out uint outBodyLen);

    // ── Raw header struct ────────────────────────────────────────────────

    [StructLayout(LayoutKind.Sequential)]
    private struct CIFHeaderRaw
    {
        public uint Type;
        public uint Width;
        public uint Height;
        public uint BodySize;
    }

    // ── Public models ────────────────────────────────────────────────────

    public record CIFHeader(uint Type, uint Width, uint Height, uint BodySize)
    {
        public bool IsPNG    => Type == 2;
        public bool IsOVL    => Type == 4;
        public bool IsLua    => Type == 3;
        public bool IsXSheet => Type == 6;
    }

    // ── Helper: extract byte array from native pointer ───────────────────

    private static byte[] ExtractBytes(nint ptr, uint size)
    {
        var buf = new byte[size];
        Marshal.Copy(ptr, buf, 0, (int)size);
        Free(ptr);
        return buf;
    }

    private static void ThrowIfFailed(int result)
    {
        if (result != 0)
            throw new InvalidOperationException(Marshal.PtrToStringUTF8(GetLastErrorPtr()) ?? "HIP native error");
    }

    // ── Public API ───────────────────────────────────────────────────────

    public static CIFHeader ReadHeader(string path)
    {
        ThrowIfFailed(ReadCIFHeader(path, out var raw));
        return new CIFHeader(raw.Type, raw.Width, raw.Height, raw.BodySize);
    }

    public static bool IsCompiledLua(string path) => IsCompiledLuaRaw(path) != 0;

    public static byte[] EncodePNG(string path, uint cifType = 2)
    {
        ThrowIfFailed(EncodePNGRaw(path, cifType, out var ptr, out var size));
        return ExtractBytes(ptr, size);
    }

    public static byte[] EncodeLua(string path, bool compileLua)
    {
        // Strip -- @encoding: comment and re-encode source to target engine encoding
        // before handing off to the native compiler, which expects single-byte input.
        string? source = null;
        try { source = File.ReadAllText(path, System.Text.Encoding.UTF8); } catch { }
        if (source != null)
        {
            int nl = source.IndexOf('\n');
            var firstLine = nl >= 0 ? source[..nl] : source;
            const string prefix = "-- @encoding:";
            if (firstLine.StartsWith(prefix, StringComparison.Ordinal))
            {
                var encName = firstLine[prefix.Length..].Trim();
                var targetEnc = EncodingFromName(encName);
                if (targetEnc != null && targetEnc.CodePage != 65001)
                {
                    var body      = nl >= 0 ? source[(nl + 1)..] : "";
                    var reencoded = targetEnc.GetBytes(body);
                    var tmp       = Path.GetTempFileName();
                    try
                    {
                        File.WriteAllBytes(tmp, reencoded);
                        return EncodeLuaCore(tmp, compileLua);
                    }
                    finally { try { File.Delete(tmp); } catch { } }
                }
            }
        }
        return EncodeLuaCore(path, compileLua);
    }

    private static byte[] EncodeLuaCore(string path, bool compileLua)
    {
        ThrowIfFailed(EncodeLuaRaw(path, compileLua ? 1 : 0, out var ptr, out var size));
        return ExtractBytes(ptr, size);
    }

    // Returns the encoding for a -- @encoding: comment name, or null if unknown.
    public static System.Text.Encoding? EncodingFromName(string name) =>
        name.ToLowerInvariant() switch
        {
            "windows-1251"         => System.Text.Encoding.GetEncoding(1251),
            "windows-1252"         => System.Text.Encoding.GetEncoding(1252),
            "windows-1250"         => System.Text.Encoding.GetEncoding(1250),
            "windows-1253"         => System.Text.Encoding.GetEncoding(1253),
            "windows-1254"         => System.Text.Encoding.GetEncoding(1254),
            "iso-8859-1" or "latin-1" => System.Text.Encoding.GetEncoding(28591),
            "utf-8"                => System.Text.Encoding.UTF8,
            _                      => null,
        };

    public static byte[] EncodeXSheet(string path)
    {
        ThrowIfFailed(EncodeXSheetRaw(path, out var ptr, out var size));
        return ExtractBytes(ptr, size);
    }

    public static byte[] DecodeCIF(string path)
    {
        ThrowIfFailed(DecodeCIFRaw(path, out var ptr, out var size));
        return ExtractBytes(ptr, size);
    }

    public static byte[] PackFolder(string folderPath, bool capitalizeNames, bool compileLua, bool useOVL,
                                     Action<int, int>? onProgress = null)
    {
        uint flags = 0;
        if (capitalizeNames) flags |= 1;
        if (compileLua)      flags |= 2;
        if (useOVL)          flags |= 4;
        ProgressCallback? cb = onProgress != null ? (cur, tot) => onProgress(cur, tot) : null;
        ThrowIfFailed(PackFolderRaw(folderPath, flags, out var ptr, out var size, cb));
        GC.KeepAlive(cb);
        return ExtractBytes(ptr, size);
    }

    public static void UnpackToFolder(string datPath, string outDir, bool extractContents,
                                       Action<int, int>? onProgress = null)
    {
        ProgressCallback? cb = onProgress != null ? (cur, tot) => onProgress(cur, tot) : null;
        ThrowIfFailed(UnpackToFolderRaw(datPath, outDir, extractContents ? 1 : 0, cb));
        GC.KeepAlive(cb);
    }

    public record CiftreeEntry(string Name, uint CIFSize, uint CIFType);

    public static uint GetCiftreeEntryCount(string datPath)
    {
        ThrowIfFailed(CiftreeEntryCountRaw(datPath, out var count));
        return count;
    }

    public static List<CiftreeEntry> GetCiftreeEntries(string datPath)
    {
        ThrowIfFailed(CiftreeEntryCountRaw(datPath, out var count));
        var entries = new List<CiftreeEntry>((int)count);
        var nameBuf = new byte[256];
        for (uint i = 0; i < count; i++)
        {
            ThrowIfFailed(CiftreeEntryInfoRaw(datPath, i, nameBuf, (uint)nameBuf.Length,
                                               out var cifSize, out var cifType));
            var name = System.Text.Encoding.UTF8.GetString(nameBuf).TrimEnd('\0');
            entries.Add(new CiftreeEntry(name, cifSize, cifType));
        }
        return entries;
    }

    public static byte[] EncodeHIS(string oggPath)
    {
        ThrowIfFailed(EncodeHISRaw(oggPath, out var ptr, out var size));
        return ExtractBytes(ptr, size);
    }

    public static byte[] DecodeHIS(string hisPath)
    {
        ThrowIfFailed(DecodeHISRaw(hisPath, out var ptr, out var size));
        return ExtractBytes(ptr, size);
    }

    public static string XSheetBodyToJson(byte[] body)
    {
        ThrowIfFailed(XSheetBodyToJsonRaw(body, (uint)body.Length, out var ptr, out var size));
        var json = Marshal.PtrToStringUTF8(ptr, (int)size);
        Free(ptr);
        return json ?? "";
    }

    public static byte[]? XSheetJsonToBody(string json)
    {
        int rc = XSheetJsonToBodyRaw(json, out var ptr, out var size);
        if (rc != 0) return null;
        return ExtractBytes(ptr, size);
    }

    // ── HIS audio helpers ────────────────────────────────────────────────

    public static byte[] EncodeHISFromAudio(string path)
    {
        ThrowIfFailed(EncodeHISFromAudioRaw(path, out var ptr, out var size));
        return ExtractBytes(ptr, size);
    }

    public static byte[] DecodeHISToFormat(string hisPath, string format)
    {
        ThrowIfFailed(DecodeHISToFormatRaw(hisPath, format, out var ptr, out var size));
        return ExtractBytes(ptr, size);
    }

    /// Runs luadec and returns raw single-byte bytes (after \ddd unescaping).
    /// Encoding interpretation is left to the caller.
    public static byte[] DecompileLuaRaw(string luacPath)
    {
        var readable = RunLuadec(luacPath);
        // Each char in `readable` carries its original byte value in the low 8 bits;
        // Latin1 maps U+0000–U+00FF → bytes 0x00–0xFF 1:1.
        return System.Text.Encoding.Latin1.GetBytes(readable);
    }

    /// Auto-detects encoding, returns decoded source with "-- @encoding: <name>"
    /// prepended when the encoding is not plain UTF-8.
    /// For non-interactive paths (batch extract, CIF decode) — picks best-guess if ambiguous.
    public static string DecompileLua(string luacPath)
    {
        var raw  = DecompileLuaRaw(luacPath);
        var (encName, decoded, candidates) = DetectSingleByteEncoding(raw);

        if (decoded == null && candidates?.Count > 0)
        {
            encName = candidates[0];
            decoded = System.Text.Encoding.GetEncoding(EncodingFromName(encName)!.CodePage).GetString(raw);
        }
        if (string.IsNullOrEmpty(decoded)) return string.Empty;

        return encName == "utf-8" ? decoded : $"-- @encoding: {encName}\n{decoded}";
    }

    /// Detects the single-byte encoding of raw decompiled bytes.
    /// Returns (encName, decoded, null) when confident, or (bestGuess, null, candidates) when ambiguous.
    public static (string EncName, string? Decoded, List<string>? Candidates)
        DetectSingleByteEncoding(byte[] raw)
    {
        // 1. Pure ASCII / valid UTF-8
        try
        {
            var decoded = new System.Text.UTF8Encoding(false, throwOnInvalidBytes: true).GetString(raw);
            return ("utf-8", decoded, null);
        }
        catch { }

        // 2. Score every candidate encoding
        var candidateDefs = new[] {
            (1251, "windows-1251"), (1252, "windows-1252"), (1250, "windows-1250"),
            (1253, "windows-1253"), (1254, "windows-1254"), (28591, "iso-8859-1"),
        };

        var scored = new List<(string Name, string Decoded, int Score)>();
        foreach (var (cp, name) in candidateDefs)
        {
            try
            {
                var dec = System.Text.Encoding.GetEncoding(cp).GetString(raw);
                scored.Add((name, dec, ScoreDecoded(dec, name)));
            }
            catch { }
        }
        scored.Sort((a, b) => b.Score.CompareTo(a.Score));

        if (scored.Count == 0)
        {
            var fb = System.Text.Encoding.GetEncoding(1251).GetString(raw);
            return ("windows-1251", fb, null);
        }

        var best       = scored[0];
        var secondScore = scored.Count > 1 ? scored[1].Score : int.MinValue;
        bool confident  = scored.Count == 1 || (best.Score - secondScore >= 4);

        if (confident) return (best.Name, best.Decoded, null);

        return (best.Name, null, scored.Take(4).Select(x => x.Name).ToList());
    }

    private static int ScoreDecoded(string text, string encName)
    {
        int cyrillic = 0, western = 0, polish = 0, greek = 0, turkish = 0, control = 0;
        int limit = Math.Min(text.Length, 4000);
        for (int i = 0; i < limit; i++)
        {
            char c = text[i];
            if      (c >= 0x0400 && c <= 0x04FF) cyrillic++;
            else if (c >= 0x0391 && c <= 0x03C9) greek++;
            else if (c is 'ą' or 'Ą' or 'ę' or 'Ę' or 'ś' or 'Ś' or 'ł' or 'Ł' or
                        'ź' or 'Ź' or 'ż' or 'Ż' or 'ć' or 'Ć' or 'ń' or 'Ń') polish++;
            else if (c is 'ğ' or 'Ğ' or 'ş' or 'Ş' or 'ı' or 'İ') turkish++;
            else if (c >= 0x00C0 && c <= 0x024F) western++;
            else if (c < 0x20 && c != '\t' && c != '\n' && c != '\r') control++;
        }
        if (control > 2) return -1000;
        return encName switch
        {
            "windows-1251" => cyrillic * 4 - western       - greek * 2 - polish * 3,
            "windows-1252" => (western - polish) * 3 - cyrillic * 4 - greek * 2,
            "windows-1250" => (western + polish * 4) * 2  - cyrillic * 4 - greek * 2,
            "windows-1253" => greek * 4 - cyrillic * 2 - western,
            "windows-1254" => (western + turkish * 5) - cyrillic * 4 - greek * 2,
            "iso-8859-1"   => western - cyrillic * 2,
            _              => 0,
        };
    }

    // Runs luadec with an inactivity watchdog: kills the process if no output
    // arrives for 15 s, so truly stuck files don't hang the app indefinitely.
    private static string RunLuadec(string luacPath)
    {
        var luadecName = RuntimeInformation.ProcessArchitecture == Architecture.Arm64
            ? "luadec-win-arm64.exe" : "luadec-win-x64.exe";
        var luadecPath = Path.Combine(AppContext.BaseDirectory, luadecName);
        if (!File.Exists(luadecPath))
            throw new InvalidOperationException($"Luadec binary not found: {luadecPath}");

        using var proc = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName               = luadecPath,
                Arguments              = $"\"{luacPath}\"",
                RedirectStandardOutput = true,
                RedirectStandardError  = true,
                UseShellExecute        = false,
                CreateNoWindow         = true,
                StandardOutputEncoding = System.Text.Encoding.Latin1,
            }
        };

        Debug.WriteLine($"[luadec] launching: {luadecPath} \"{luacPath}\"");
        proc.Start();

        var sb           = new System.Text.StringBuilder();
        var lastActivity = DateTime.UtcNow;
        var timedOut     = false;

        // Read stdout in chunks so we can track when bytes last arrived.
        var stdoutTask = Task.Run(async () => {
            var buf = new char[4096];
            while (true)
            {
                int n = await proc.StandardOutput.ReadAsync(buf, 0, buf.Length).ConfigureAwait(false);
                if (n == 0) break;
                sb.Append(buf, 0, n);
                lastActivity = DateTime.UtcNow;
                Debug.WriteLine($"[luadec] +{n} chars (total {sb.Length})");
            }
        });

        var stderrTask = proc.StandardError.ReadToEndAsync();

        // Watchdog: check every 2 s; kill if idle for ≥ 15 s.
        var watchdog = Task.Run(async () => {
            while (!proc.HasExited)
            {
                await Task.Delay(2000).ConfigureAwait(false);
                if (proc.HasExited) break;
                var idle = (DateTime.UtcNow - lastActivity).TotalSeconds;
                if (idle >= 15)
                {
                    Debug.WriteLine($"[luadec] no output for {idle:0}s — killing");
                    timedOut = true;
                    try { proc.Kill(); } catch { }
                    break;
                }
                Debug.WriteLine($"[luadec] still running (idle {idle:0}s, {sb.Length} chars)");
            }
        });

        Task.WaitAll(stdoutTask, stderrTask, watchdog);

        if (timedOut)
            throw new InvalidOperationException("Decompilation timed out — luadec produced no output for 15 s");

        if (proc.ExitCode != 0)
        {
            var stderr = stderrTask.Result;
            throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(stderr)
                    ? $"luadec exited with code {proc.ExitCode}"
                    : stderr.Trim());
        }

        return LuaDecompiledToReadable(sb.ToString());
    }

    /// luadec writes bytes >= 128 in string literals as decimal "\ddd" (and
    /// sometimes "\xHH") escapes, so Cyrillic/accented text comes out as codes.
    /// Turn those numeric escapes back into raw bytes (kept as U+00xx chars),
    /// leaving real escapes (\n, \t, \", \\, low control bytes) intact. Write
    /// the result with Encoding.Latin1 to preserve the original code page 1:1.
    public static string LuaDecompiledToReadable(string src)
    {
        var sb = new System.Text.StringBuilder(src.Length);
        int n = src.Length;
        static int Hex(char ch)
        {
            if (ch >= '0' && ch <= '9') return ch - '0';
            ch = char.ToLowerInvariant(ch);
            return (ch >= 'a' && ch <= 'f') ? ch - 'a' + 10 : -1;
        }
        for (int i = 0; i < n;)
        {
            char c = src[i];
            if (c != '\\' || i + 1 >= n) { sb.Append(c); i++; continue; }
            char d = src[i + 1];
            if (d == '\\') { sb.Append("\\\\"); i += 2; continue; }
            if (d >= '0' && d <= '9')
            {
                int v = 0, k = 0, j = i + 1;
                while (j < n && k < 3 && src[j] >= '0' && src[j] <= '9') { v = v * 10 + (src[j] - '0'); j++; k++; }
                if (v >= 128 && v <= 255) { sb.Append((char)v); i = j; continue; }
                sb.Append('\\'); i++; continue;
            }
            if (d == 'x' || d == 'X')
            {
                int v = 0, k = 0, j = i + 2;
                while (j < n && k < 2) { int h = Hex(src[j]); if (h < 0) break; v = v * 16 + h; j++; k++; }
                if (k > 0 && v >= 128 && v <= 255) { sb.Append((char)v); i = j; continue; }
                sb.Append('\\'); i++; continue;
            }
            sb.Append('\\'); sb.Append(d); i += 2;
        }
        return sb.ToString();
    }
}
