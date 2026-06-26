using System.Net.Http;
using System.Reflection;

namespace HIPToolkit;

/// <summary>
/// Checks the repository's <c>main</c> branch for a newer version once per launch.
/// Network failures are swallowed silently — the check must never block or disrupt
/// startup.
/// </summary>
internal static class UpdateChecker
{
    private const string VersionUrl  = "https://raw.githubusercontent.com/loinik/hip-toolkit/main/VERSION";
    public  const string ReleasesUrl = "https://github.com/loinik/hip-toolkit/releases/latest";

    public static string CurrentVersion
    {
        get
        {
            var info = Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (!string.IsNullOrEmpty(info))
            {
                var plus = info.IndexOf('+');          // strip "+<commit>" metadata, if any
                return plus >= 0 ? info[..plus] : info;
            }
            var v = Assembly.GetExecutingAssembly().GetName().Version;
            return v == null ? "0" : $"{v.Major}.{v.Minor}.{v.Build}";
        }
    }

    /// <summary>Returns the newer remote version string if an update is available, else null.</summary>
    public static async Task<string?> CheckAsync()
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("HIP-Toolkit-UpdateCheck");
            var remote = (await http.GetStringAsync(VersionUrl)).Trim();
            if (string.IsNullOrEmpty(remote)) return null;
            return IsNewer(remote, CurrentVersion) ? remote : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Dot-separated integer comparison: true when <paramref name="a"/> is strictly newer than <paramref name="b"/>.</summary>
    public static bool IsNewer(string a, string b)
    {
        int[] pa = Parse(a), pb = Parse(b);
        for (int i = 0; i < Math.Max(pa.Length, pb.Length); i++)
        {
            int x = i < pa.Length ? pa[i] : 0;
            int y = i < pb.Length ? pb[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    private static int[] Parse(string v) =>
        v.Split('.').Select(s => int.TryParse(s, out var n) ? n : 0).ToArray();
}
