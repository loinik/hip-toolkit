using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.UI;

namespace HIPToolkit;

public sealed partial class PreviewWindow : Window
{
    // ── Single-instance ───────────────────────────────────────────────────

    public static void Show(string path)
    {
        var existing = App.CurrentPreview;
        if (existing != null)
        {
            existing.AppWindow.Show();
            existing.Activate();
            existing.AddFileTab(path);
        }
        else
        {
            var w = new PreviewWindow();
            w.Activate();
            w.AddFileTab(path);
        }
    }

    public PreviewWindow()
    {
        InitializeComponent();
        Title = "HIP Toolkit — Preview";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(960, 680));

        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.ButtonBackgroundColor         = Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;

        // Enforce minimum size
        AppWindow.Changed += (sender, args) =>
        {
            if (!args.DidSizeChange) return;
            var s = sender.Size;
            if (s.Width < 520 || s.Height < 380)
                sender.Resize(new Windows.Graphics.SizeInt32(
                    Math.Max(s.Width, 520), Math.Max(s.Height, 380)));
        };

        App.RegisterPreview(this);
        TabStrip.SelectionChanged += (_, _) => UpdateRevealButton();
        UpdateRevealButton();
        UpdateDropHint();
    }

    // ── Tab management ────────────────────────────────────────────────────

    public void AddFileTab(string path)
    {
        // Can be called from any thread
        if (!DispatcherQueue.HasThreadAccess)
        {
            DispatcherQueue.TryEnqueue(() => AddFileTab(path));
            return;
        }

        foreach (TabViewItem existing in TabStrip.TabItems)
        {
            if (existing.Tag as string == path)
            {
                TabStrip.SelectedItem = existing;
                return;
            }
        }

        var wrapper = MakeWrapper();
        var tab = new TabViewItem
        {
            Header     = Path.GetFileName(path),
            Tag        = path,
            IsClosable = true,
            Content    = wrapper
        };
        TabStrip.TabItems.Add(tab);
        TabStrip.SelectedItem = tab;
        UpdateDropHint();
        BeginLoad(tab, path, wrapper);
    }

    private void OnTabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs e)
    {
        sender.TabItems.Remove(e.Tab);
        UpdateDropHint();
        if (sender.TabItems.Count == 0) Close();
    }

    private void OnAddTabButtonClick(TabView sender, object args)
    {
        // wrapper never gets replaced — only its Children change, which always triggers layout
        var wrapper = new Grid();
        var tab = new TabViewItem { Header = "New Tab", IsClosable = true, Content = wrapper };
        wrapper.Children.Add(MakeDropZonePanel(tab, wrapper));
        sender.TabItems.Add(tab);
        sender.SelectedItem = tab;
        UpdateDropHint();
    }

    private void UpdateRevealButton() =>
        BtnReveal.IsEnabled = TabStrip.SelectedItem is TabViewItem { Tag: string };

    private void UpdateDropHint() =>
        DropHint.Visibility = TabStrip.TabItems.Count == 0
            ? Visibility.Visible : Visibility.Collapsed;

    // ── Loading: two-phase (I/O on background, UI on dispatcher) ─────────
    //
    // Avoids the async/await continuation marshalling issue in WinUI 3 where
    // a continuation posted back via SynchronizationContext from inside a
    // TryEnqueue callback can silently stall until the queue is pumped again.

    private sealed record DataResult(
        string Kind,
        HIPInterop.CIFHeader? Header = null,
        byte[]?               Bytes  = null,
        string?               TmpPath = null,
        string?               Text    = null,
        uint                  EntryCount = 0,
        long                  FileSize   = 0,
        string?               Error   = null
    );

    // Creates a spinner-containing Grid that lives as tab.Content for the whole lifetime of the load.
    // BeginLoad mutates its Children in-place — modifying an existing visual-tree node reliably
    // triggers layout, unlike replacing tab.Content which WinUI 3 can defer until focus changes.
    private static Grid MakeWrapper()
    {
        var spinner = new ProgressRing { IsActive = true, Width = 36, Height = 36,
                                         HorizontalAlignment = HorizontalAlignment.Center,
                                         VerticalAlignment   = VerticalAlignment.Center };
        var g = new Grid();
        g.Children.Add(spinner);
        return g;
    }

    private void BeginLoad(TabViewItem tab, string path, Grid wrapper)
    {
        var dq = DispatcherQueue;
        _ = Task.Run(() =>
        {
            var result  = GatherData(path);
            var content = null as UIElement; // placeholder; built on UI thread below
            dq.TryEnqueue(() =>
            {
                content = BuildContent(result, path, tab);
                wrapper.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
                wrapper.Children.Clear();
                wrapper.Children.Add(content);
            });
        });
    }

    private static DataResult GatherData(string path)
    {
        try
        {
            var ext = Path.GetExtension(path).ToLowerInvariant();
            switch (ext)
            {
                case ".cif":
                {
                    var h = HIPInterop.ReadHeader(path);
                    var d = HIPInterop.DecodeCIF(path);
                    if (h.IsPNG || h.IsOVL)
                    {
                        var tmp = Path.Combine(Path.GetTempPath(), $"hip_{Guid.NewGuid():N}.png");
                        File.WriteAllBytes(tmp, d);
                        return new DataResult("cif-image", Header: h, Bytes: d, TmpPath: tmp);
                    }
                    if (h.IsLua)
                    {
                        bool compiled = d.Length >= 4 && d[0] == 0x1B && d[1] == 0x4C;
                        return new DataResult(
                            compiled ? "cif-lua-compiled" : "cif-lua-source",
                            Header: h, Bytes: d,
                            Text: compiled ? null : System.Text.Encoding.UTF8.GetString(d),
                            FileSize: d.LongLength);
                    }
                    if (h.IsXSheet)
                        return new DataResult("cif-xsheet", Header: h, FileSize: d.LongLength);
                    return new DataResult("cif-unknown", Header: h, FileSize: d.LongLength);
                }
                case ".lua":
                {
                    var d = File.ReadAllBytes(path);
                    bool compiled = d.Length >= 4 && d[0] == 0x1B && d[1] == 0x4C;
                    return new DataResult(
                        compiled ? "lua-compiled" : "lua-source",
                        Bytes: d,
                        Text: compiled ? null : System.Text.Encoding.UTF8.GetString(d),
                        FileSize: d.LongLength);
                }
                case ".dat":
                {
                    uint count = 0;
                    try { count = HIPInterop.GetCiftreeEntryCount(path); } catch { /* ignore */ }
                    return new DataResult("dat", EntryCount: count, FileSize: new FileInfo(path).Length);
                }
                case ".his":
                    return new DataResult("his", FileSize: new FileInfo(path).Length);
                default:
                    return new DataResult("unknown", FileSize: new FileInfo(path).Length);
            }
        }
        catch (Exception ex)
        {
            return new DataResult("error", Error: ex.Message);
        }
    }

    private UIElement BuildContent(DataResult r, string path, TabViewItem tab)
    {
        if (r.Error != null)
            return InfoPanel("", "Error", r.Error);

        return r.Kind switch
        {
            "cif-image" => ImageLayout(
                new BitmapImage(new Uri(r.TmpPath!)),
                r.Header!, r.Bytes!, path),

            "cif-lua-compiled" or "lua-compiled" =>
                LuaBytecodePanel(r.Bytes!, path, tab),

            "cif-lua-source" or "lua-source" =>
                CodeLayout(r.Text!, "Lua source", FormatSize(r.FileSize)),

            "cif-xsheet" =>
                InfoPanel("", "XSheet Sprite Data", $"Frame data  ·  {FormatSize(r.FileSize)}"),

            "dat" => InfoPanel("", "Ciftree Archive",
                r.EntryCount > 0
                    ? $"{r.EntryCount} entries  ·  {FormatSize(r.FileSize)}\n\nUse the converter (Unpack) to extract all files."
                    : $"{FormatSize(r.FileSize)}\n\nUse the converter (Unpack) to extract all files."),

            "his" => InfoPanel("", "HIS Audio File",
                $"Use the converter (HIS → OGG) to extract audio.\n\n{FormatSize(r.FileSize)}"),

            _ => InfoPanel("", Path.GetFileName(path),
                $"No preview for {Path.GetExtension(path).ToUpperInvariant()} files.")
        };
    }

    // ── Toolbar ───────────────────────────────────────────────────────────

    private async void BtnOpenFile_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        foreach (var ext in new[] { ".cif", ".his", ".dat", ".lua", ".png" })
            picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(
            picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        foreach (var f in files) AddFileTab(f.Path);
    }

    private void BtnReveal_Click(object sender, RoutedEventArgs e)
    {
        if (TabStrip.SelectedItem is TabViewItem { Tag: string path })
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\"");
    }

    // ── Drag and drop onto tab strip ──────────────────────────────────────

    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Open for preview";
            e.DragUIOverride.IsCaptionVisible = true;
        }
    }

    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        foreach (var item in items) AddFileTab(item.Path);
    }

    // ── Drop zone tab (opened via "+" button) ─────────────────────────────

    // outerWrapper is already set as owner.Content — we only ever mutate its Children
    private UIElement MakeDropZonePanel(TabViewItem owner, Grid outerWrapper)
    {
        var icon = new FontIcon
        {
            Glyph      = "",
            FontSize   = 36,
            Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"],
            Margin     = new Thickness(0, 0, 0, 14)
        };
        var title = new TextBlock
        {
            Text = "Drop a file to preview",
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 6)
        };
        var subtitle = new TextBlock
        {
            Text = "CIF · HIS · DAT · Lua · PNG",
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 20)
        };
        var chooseBtn = new Button
        {
            Content = "Choose File…",
            HorizontalAlignment = HorizontalAlignment.Center
        };

        var stack = new StackPanel
        {
            VerticalAlignment   = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center
        };
        stack.Children.Add(icon);
        stack.Children.Add(title);
        stack.Children.Add(subtitle);
        stack.Children.Add(chooseBtn);

        var zone = new Border
        {
            BorderBrush     = (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"],
            BorderThickness = new Thickness(2),
            CornerRadius    = new CornerRadius(8),
            Margin          = new Thickness(24),
            AllowDrop       = true,
            Child           = stack,
            Background      = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"]
        };

        void LoadIntoTab(string path)
        {
            owner.Header = Path.GetFileName(path);
            owner.Tag    = path;
            // Mutate outerWrapper.Children — never replace owner.Content —
            // so WinUI 3 sees the change immediately on the active tab.
            outerWrapper.Children.Clear();
            var spinner = new ProgressRing
            {
                IsActive = true, Width = 36, Height = 36,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment   = VerticalAlignment.Center
            };
            outerWrapper.Children.Add(spinner);
            BeginLoad(owner, path, outerWrapper);
        }

        zone.DragOver += (_, ev) =>
        {
            if (ev.DataView.Contains(StandardDataFormats.StorageItems))
                ev.AcceptedOperation = DataPackageOperation.Copy;
        };
        zone.Drop += async (_, ev) =>
        {
            if (!ev.DataView.Contains(StandardDataFormats.StorageItems)) return;
            var items = await ev.DataView.GetStorageItemsAsync();
            if (items.Count > 0) LoadIntoTab(items[0].Path);
        };
        chooseBtn.Click += async (_, _) =>
        {
            var picker = new FileOpenPicker();
            picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
            foreach (var ext in new[] { ".cif", ".his", ".dat", ".lua", ".png" })
                picker.FileTypeFilter.Add(ext);
            WinRT.Interop.InitializeWithWindow.Initialize(
                picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var file = await picker.PickSingleFileAsync();
            if (file != null) LoadIntoTab(file.Path);
        };

        return zone;
    }

    // ── Layout builders ───────────────────────────────────────────────────

    private UIElement ImageLayout(BitmapImage bitmap, HIPInterop.CIFHeader header,
                                   byte[] data, string sourcePath)
    {
        var img = new Image
        {
            Source  = bitmap,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment   = VerticalAlignment.Center
        };

        FrameworkElement imgContainer;
        if (header.IsOVL)
        {
            var bg = new Grid { Background = new SolidColorBrush(Color.FromArgb(255, 160, 160, 160)) };
            bg.Children.Add(img);
            imgContainer = bg;
        }
        else { imgContainer = img; }

        var scroll = new ScrollViewer
        {
            Content = imgContainer,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility   = ScrollBarVisibility.Auto
        };

        var dimText = header.Width > 0
            ? $"{header.Width} × {header.Height} px{(header.IsOVL ? "  ·  OVL" : "")}"
            : (header.IsOVL ? "OVL" : "PNG");

        var dimLabel = new TextBlock
        {
            Text = dimText,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            Margin = new Thickness(16, 0, 0, 0)
        };

        var exportBtn = new Button
        {
            Content = "Export PNG…",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0)
        };
        exportBtn.Click += async (_, _) =>
            await ExportFileAsync(data, sourcePath, "PNG Image", ".png");

        var fileLabel = new TextBlock
        {
            Text = Path.GetFileName(sourcePath),
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"],
            Margin = new Thickness(0, 0, 16, 0)
        };

        var barRow = new Grid { Height = 44 };
        barRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        barRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        barRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(dimLabel,  0);
        Grid.SetColumn(exportBtn, 1);
        Grid.SetColumn(fileLabel, 2);
        barRow.Children.Add(dimLabel);
        barRow.Children.Add(exportBtn);
        barRow.Children.Add(fileLabel);

        return RowLayout(scroll, barRow);
    }

    private UIElement LuaBytecodePanel(byte[] data, string sourcePath, TabViewItem tab)
    {
        var icon = new FontIcon
        {
            Glyph = "",
            FontSize = 40,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            Margin = new Thickness(0, 0, 0, 12)
        };
        var title = new TextBlock
        {
            Text = "Compiled Lua bytecode",
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 4)
        };
        var sizeLabel = new TextBlock
        {
            Text = FormatSize(data.Length),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 12)
        };
        var hint = new TextBlock
        {
            Text = "Enable \"Decompile Lua\" in the converter (CIF → File)\nto extract readable source code.",
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            TextWrapping  = TextWrapping.WrapWholeWords,
            MaxWidth = 400,
            Margin = new Thickness(0, 0, 0, 16)
        };
        var saveBtn = new Button
        {
            Content = "Save Bytecode (.lua)…",
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 8)
        };
        saveBtn.Click += async (_, _) =>
            await ExportFileAsync(data, sourcePath, "Lua file", ".lua");

        var decompileBtn = new Button
        {
            Content = "Decompile…",
            HorizontalAlignment = HorizontalAlignment.Center
        };
        decompileBtn.Click += (_, _) => DecompileIntoTab(data, sourcePath, tab, decompileBtn);

        var panel = new StackPanel
        {
            VerticalAlignment   = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center
        };
        panel.Children.Add(icon);
        panel.Children.Add(title);
        panel.Children.Add(sizeLabel);
        panel.Children.Add(hint);
        panel.Children.Add(saveBtn);
        panel.Children.Add(decompileBtn);
        return panel;
    }

    private void DecompileIntoTab(byte[] data, string sourcePath, TabViewItem tab, Button btn)
    {
        btn.Content   = "Decompiling…";
        btn.IsEnabled = false;
        var dq = DispatcherQueue;
        _ = Task.Run(() =>
        {
            string? source = null;
            string? error  = null;
            var tmp = Path.Combine(Path.GetTempPath(), $"hip_{Guid.NewGuid():N}.lua");
            try
            {
                File.WriteAllBytes(tmp, data);
                source = HIPInterop.DecompileLua(tmp);
                if (string.IsNullOrEmpty(source)) error = "empty output";
            }
            catch (Exception ex) { error = ex.Message; }
            finally { try { File.Delete(tmp); } catch { /* ignore */ } }

            dq.TryEnqueue(() =>
            {
                if (source != null)
                {
                    var wrapper = (Grid)tab.Content;
                    wrapper.Background = (Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
                    wrapper.Children.Clear();
                    wrapper.Children.Add(CodeLayout(source!, "Decompiled Lua", FormatSize(source!.Length)));
                }
                else
                {
                    btn.Content   = $"Failed: {error}";
                    btn.IsEnabled = true;
                }
            });
        });
    }

    private static UIElement CodeLayout(string text, string badge, string sizeStr)
    {
        var codeBlock = new TextBlock
        {
            Text       = text,
            FontFamily = new FontFamily("Consolas"),
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.NoWrap,
            Margin = new Thickness(16)
        };
        var scroll = new ScrollViewer
        {
            Content = codeBlock,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility   = ScrollBarVisibility.Auto
        };
        var bar = new TextBlock
        {
            Text = $"{badge}  ·  {sizeStr}",
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            Margin = new Thickness(16, 0, 0, 0)
        };
        return RowLayout(scroll, bar);
    }

    private static UIElement InfoPanel(string glyph, string title, string message)
    {
        var icon = new FontIcon
        {
            Glyph    = glyph,
            FontSize = 40,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            Margin = new Thickness(0, 0, 0, 12)
        };
        var titleBlock = new TextBlock
        {
            Text = title,
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 8)
        };
        var detailBlock = new TextBlock
        {
            Text = message,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            TextWrapping  = TextWrapping.WrapWholeWords,
            MaxWidth = 400
        };
        var panel = new StackPanel
        {
            VerticalAlignment   = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center
        };
        panel.Children.Add(icon);
        panel.Children.Add(titleBlock);
        panel.Children.Add(detailBlock);
        return panel;
    }

    // Top area fills available space; bottom area gets a separator line
    private static UIElement RowLayout(UIElement top, UIElement bottom)
    {
        var bar = new Border
        {
            BorderBrush     = (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"],
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = bottom as FrameworkElement
        };
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow((FrameworkElement)top, 0);
        Grid.SetRow(bar,                   1);
        root.Children.Add(top);
        root.Children.Add(bar);
        return root;
    }

    // ── Export ────────────────────────────────────────────────────────────

    private async Task ExportFileAsync(byte[] data, string sourcePath, string typeName, string ext)
    {
        var picker = new FileSavePicker();
        picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        picker.SuggestedFileName = Path.GetFileNameWithoutExtension(sourcePath);
        picker.FileTypeChoices.Add(typeName, [ext]);
        WinRT.Interop.InitializeWithWindow.Initialize(
            picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSaveFileAsync();
        if (file != null) await FileIO.WriteBytesAsync(file, data);
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private static string FormatSize(long bytes) => bytes switch
    {
        < 1024       => $"{bytes} B",
        < 1048576    => $"{bytes / 1024.0:F1} KB",
        < 1073741824 => $"{bytes / 1048576.0:F1} MB",
        _            => $"{bytes / 1073741824.0:F2} GB"
    };
}
