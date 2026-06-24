using System.IO.Pipes;
using Microsoft.UI.Xaml;

namespace HIPToolkit;

public partial class App : Application
{
    private const string PreviewPipe = "HIPToolkitPreview";

    private Window? _window;
    private PreviewWindow? _preview;

    // Exposed so PreviewWindow.Show() can reuse the existing instance in-process
    private static PreviewWindow? _currentPreview;
    public static PreviewWindow? CurrentPreview => _currentPreview;

    public static void RegisterPreview(PreviewWindow w)
    {
        _currentPreview = w;
        w.Closed += (_, _) => { if (_currentPreview == w) _currentPreview = null; };
    }

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        FileAssociations.Register();

        var cmdArgs  = Environment.GetCommandLineArgs();
        var filePath = cmdArgs.Length >= 2 && File.Exists(cmdArgs[1]) ? cmdArgs[1] : null;

        if (filePath != null)
        {
            // Try to hand off to an already-running preview instance via named pipe
            if (TrySendToExistingPreview(filePath))
            {
                Exit();
                return;
            }

            // We are the first preview process
            _preview = new PreviewWindow();
            _preview.Activate();
            _preview.AddFileTab(filePath);
            _preview.Closed += (_, _) => Exit();

            _ = ListenForFilesAsync();
        }
        else
        {
            _window = new MainWindow();
            _window.Activate();
        }
    }

    // ── Named-pipe single-instance ────────────────────────────────────────

    private static bool TrySendToExistingPreview(string path)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PreviewPipe, PipeDirection.Out);
            client.Connect(400);
            using var writer = new StreamWriter(client) { AutoFlush = true };
            writer.WriteLine(path);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private async Task ListenForFilesAsync()
    {
        while (_preview != null)
        {
            try
            {
                using var server = new NamedPipeServerStream(
                    PreviewPipe, PipeDirection.In, maxNumberOfServerInstances: 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous);

                await server.WaitForConnectionAsync();

                using var reader = new StreamReader(server);
                var line = await reader.ReadLineAsync();
                if (!string.IsNullOrWhiteSpace(line))
                {
                    var path = line.Trim();
                    _preview?.DispatcherQueue.TryEnqueue(() =>
                    {
                        // Restore from taskbar if minimized
                        _preview?.AppWindow.Show();
                        _preview?.Activate();
                        _preview?.AddFileTab(path);
                    });
                }
            }
            catch
            {
                await Task.Delay(100);
            }
        }
    }
}
