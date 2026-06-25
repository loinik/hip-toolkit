using System.Runtime.InteropServices;

namespace HIPToolkit;

internal static class TaskbarProgress
{
    private enum TbpFlag { NoProgress = 0, Normal = 2 }

    [ComImport]
    [Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITaskbarList3
    {
        void HrInit();
        void AddTab(nint hwnd);
        void DeleteTab(nint hwnd);
        void ActivateTab(nint hwnd);
        void SetActiveAlt(nint hwnd);
        void MarkFullscreenWindow(nint hwnd, [MarshalAs(UnmanagedType.Bool)] bool full);
        void SetProgressValue(nint hwnd, ulong completed, ulong total);
        void SetProgressState(nint hwnd, int flags);
    }

    [ComImport]
    [Guid("56fdf344-fd6d-11d0-958a-006097c9a090")]
    [ClassInterface(ClassInterfaceType.None)]
    private class TaskbarInstance { }

    private static readonly ITaskbarList3? _tb;

    static TaskbarProgress()
    {
        try { _tb = (ITaskbarList3)new TaskbarInstance(); _tb.HrInit(); }
        catch { }
    }

    public static void Set(nint hwnd, int current, int total)
    {
        try
        {
            _tb?.SetProgressState(hwnd, (int)TbpFlag.Normal);
            _tb?.SetProgressValue(hwnd, (ulong)current, (ulong)total);
        }
        catch { }
    }

    public static void Clear(nint hwnd)
    {
        try { _tb?.SetProgressState(hwnd, (int)TbpFlag.NoProgress); }
        catch { }
    }
}
