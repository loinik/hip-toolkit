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
        ThrowIfFailed(EncodeLuaRaw(path, compileLua ? 1 : 0, out var ptr, out var size));
        return ExtractBytes(ptr, size);
    }

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

    public static string DecompileLua(string luacPath)
    {
        var luadecName = RuntimeInformation.ProcessArchitecture == Architecture.Arm64
            ? "luadec-win-arm64.exe"
            : "luadec-win-x64.exe";

        var appDir = AppContext.BaseDirectory;
        var luadecPath = Path.Combine(appDir, luadecName);

        if (!File.Exists(luadecPath))
            throw new InvalidOperationException($"Luadec binary not found: {luadecPath}");

        using var proc = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = luadecPath,
                Arguments = $"\"{luacPath}\"",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            }
        };

        System.Diagnostics.Debug.WriteLine($"[luadec] launching: {luadecPath} \"{luacPath}\"");
        proc.Start();
        // Read async to avoid pipe-buffer deadlock, kill if luadec hangs on bad bytecode
        var stdoutTask = proc.StandardOutput.ReadToEndAsync();
        var stderrTask = proc.StandardError.ReadToEndAsync();
        bool finished  = proc.WaitForExit(15_000); // 15-second timeout
        if (!finished)
        {
            try { proc.Kill(); } catch { /* ignore */ }
            throw new InvalidOperationException("Decompilation timed out — luadec got stuck on this bytecode");
        }
        var stdout = stdoutTask.GetAwaiter().GetResult();
        var stderr = stderrTask.GetAwaiter().GetResult();

        if (proc.ExitCode != 0)
            throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(stderr) ? $"luadec exited with code {proc.ExitCode}" : stderr.Trim());

        return stdout;
    }
}
