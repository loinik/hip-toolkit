using System.Text.Json;

namespace HIPToolkit;

/// <summary>
/// Runtime loader for Sources/Strings/en.json (and future language files).
/// Usage: S.Get("key")  or  S.Fmt("key_with_{0}", arg)
/// </summary>
internal static class S
{
    private static Dictionary<string, string> _dict = [];

    public static void Load(string baseDir)
    {
        var path = Path.Combine(baseDir, "Strings", "en.json");
        if (!File.Exists(path)) return;
        try
        {
            var json = File.ReadAllText(path, System.Text.Encoding.UTF8);
            _dict = JsonSerializer.Deserialize<Dictionary<string, string>>(json) ?? [];
        }
        catch { /* fall back to key-as-value if JSON is missing or broken */ }
    }

    public static string Get(string key) =>
        _dict.TryGetValue(key, out var v) ? v : key;

    public static string Fmt(string key, params object?[] args)
    {
        var s = Get(key);
        for (int i = 0; i < args.Length; i++)
            s = s.Replace($"{{{i}}}", args[i]?.ToString() ?? "");
        return s;
    }
}
