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

    [DllImport(DllName, EntryPoint = "HIP_PackFolder")]
    private static extern int PackFolderRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string folderPath,
        uint flags,
        out nint data,
        out uint size);

    [DllImport(DllName, EntryPoint = "HIP_UnpackToFolder")]
    private static extern int UnpackToFolderRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string datPath,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string outDir,
        int extractContents);

    [DllImport(DllName, EntryPoint = "HIP_CiftreeEntryCount")]
    private static extern int CiftreeEntryCountRaw(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string datPath,
        out uint count);

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

    public static byte[] PackFolder(string folderPath, bool capitalizeNames, bool compileLua, bool useOVL)
    {
        uint flags = 0;
        if (capitalizeNames) flags |= 1;
        if (compileLua)      flags |= 2;
        if (useOVL)          flags |= 4;
        ThrowIfFailed(PackFolderRaw(folderPath, flags, out var ptr, out var size));
        return ExtractBytes(ptr, size);
    }

    public static void UnpackToFolder(string datPath, string outDir, bool extractContents)
    {
        ThrowIfFailed(UnpackToFolderRaw(datPath, outDir, extractContents ? 1 : 0));
    }

    public static uint GetCiftreeEntryCount(string datPath)
    {
        ThrowIfFailed(CiftreeEntryCountRaw(datPath, out var count));
        return count;
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

        proc.Start();
        var stdout = proc.StandardOutput.ReadToEnd();
        var stderr = proc.StandardError.ReadToEnd();
        proc.WaitForExit();

        if (proc.ExitCode != 0)
            throw new InvalidOperationException(
                string.IsNullOrWhiteSpace(stderr) ? $"luadec exited with code {proc.ExitCode}" : stderr.Trim());

        return stdout;
    }
}
