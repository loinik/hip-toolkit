using Microsoft.Win32;

namespace HIPToolkit;

/// <summary>
/// Registers file associations for .cif / .his / .dat under HKCU — no admin or certificate needed.
/// </summary>
internal static class FileAssociations
{
    private static readonly (string ext, string progId, string description)[] Associations =
    [
        (".cif",  "HIPToolkit.cif", "HIP CIF File"),
        (".his",  "HIPToolkit.his", "HIP HIS Audio File"),
        (".dat",  "HIPToolkit.dat", "HIP Ciftree Archive"),
    ];

    public static void Register()
    {
        var exe = Environment.ProcessPath;
        if (exe is null) return;

        var command = $"\"{exe}\" \"%1\"";

        using var classesRoot = Registry.CurrentUser.OpenSubKey(@"Software\Classes", writable: true)
                             ?? Registry.CurrentUser.CreateSubKey(@"Software\Classes");

        foreach (var (ext, progId, description) in Associations)
        {
            // .ext → ProgID
            using (var extKey = classesRoot.CreateSubKey(ext))
                extKey.SetValue("", progId);

            // ProgID → shell open command
            using var progKey = classesRoot.CreateSubKey(progId);
            progKey.SetValue("", description);
            using var cmdKey = progKey.CreateSubKey(@"shell\open\command");
            cmdKey.SetValue("", command);
        }

        // Tell Explorer to refresh file associations
        SHChangeNotify();
    }

    [System.Runtime.InteropServices.DllImport("shell32.dll")]
    private static extern void SHChangeNotify(
        int wEventId = 0x08000000,   // SHCNE_ASSOCCHANGED
        uint uFlags  = 0,
        nint dwItem1 = 0,
        nint dwItem2 = 0);
}
