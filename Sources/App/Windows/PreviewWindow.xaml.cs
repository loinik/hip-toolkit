using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.Media.Core;
using Windows.Media.Playback;
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
            w.AppWindow.Show();
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
        string?               Error   = null,
        List<HIPInterop.CiftreeEntry>? Entries = null
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
            DataResult result;
            try { result = GatherData(path); }
            catch (Exception ex) { result = new DataResult("error", Error: ex.Message); }

            dq.TryEnqueue(() =>
            {
                UIElement content;
                try { content = BuildContent(result, path, tab); }
                catch (Exception ex) { content = InfoPanel("", "Render Error", ex.Message); }

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
                    List<HIPInterop.CiftreeEntry>? entries = null;
                    string? readError = null;
                    try { entries = HIPInterop.GetCiftreeEntries(path); }
                    catch (Exception ex) { readError = ex.Message; }
                    if (readError != null)
                        return new DataResult("dat-error", Error: readError, FileSize: new FileInfo(path).Length);
                    return new DataResult("dat",
                        EntryCount: (uint)(entries?.Count ?? 0),
                        FileSize:   new FileInfo(path).Length,
                        Entries:    entries);
                }
                case ".his":
                {
                    try
                    {
                        var wav = HIPInterop.DecodeHISToFormat(path, "wav");
                        var tmp = Path.Combine(Path.GetTempPath(), $"hip_{Guid.NewGuid():N}.wav");
                        File.WriteAllBytes(tmp, wav);
                        return new DataResult("his-audio", TmpPath: tmp, FileSize: new FileInfo(path).Length);
                    }
                    catch (Exception ex)
                    {
                        return new DataResult("his", FileSize: new FileInfo(path).Length, Error: ex.Message);
                    }
                }
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

            "dat-error" => InfoPanel("", "Cannot Read Archive",
                $"{r.Error}\n\nThis file may not be a valid Ciftree archive."),

            "dat" => r.Entries is { Count: > 0 }
                ? CiftreeEntriesPanel(r.Entries, r.FileSize)
                : InfoPanel("", "Ciftree Archive",
                    $"{FormatSize(r.FileSize)}\n\nEmpty archive or no entries found."),

            "his-audio" => HISAudioPanel(r.TmpPath!, path, r.FileSize),

            "his" => InfoPanel("", "HIS Audio File",
                $"{(r.Error != null ? r.Error + "\n\n" : "")}Cannot decode audio.\n{FormatSize(r.FileSize)}"),

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

    private UIElement CiftreeEntriesPanel(List<HIPInterop.CiftreeEntry> entries, long fileSize)
    {
        var header = new TextBlock
        {
            Text = $"{entries.Count} entries  ·  {FormatSize(fileSize)}",
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            Margin = new Thickness(16, 0, 0, 0)
        };

        var list = new ListView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = false };
        foreach (var entry in entries)
        {
            var glyph = entry.CIFType switch
            {
                2 or 4 => "",  // Photo (Segoe MDL2)
                6      => "",  // Table
                _      => ""   // Document
            };
            var icon = new FontIcon
            {
                Glyph = glyph, FontSize = 14, Width = 20,
                Foreground = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"]
            };
            var nameBlock = new TextBlock
            {
                Text = entry.Name + ".cif",
                FontFamily = new FontFamily("Consolas"),
                VerticalAlignment = VerticalAlignment.Center
            };
            var sizeBlock = new TextBlock
            {
                Text = FormatSize(entry.CIFSize),
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Right,
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]
            };
            var row = new Grid { Padding = new Thickness(0, 3, 0, 3) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(icon,      0);
            Grid.SetColumn(nameBlock, 1);
            Grid.SetColumn(sizeBlock, 2);
            row.Children.Add(icon);
            row.Children.Add(nameBlock);
            row.Children.Add(sizeBlock);
            list.Items.Add(new ListViewItem { Content = row, Padding = new Thickness(8, 2, 8, 2) });
        }

        var scroll = new ScrollViewer
        {
            Content = list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled
        };

        return RowLayout(scroll, header);
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

    // ── HIS Audio Player ─────────────────────────────────────────────────

    private UIElement HISAudioPanel(string tmpWavPath, string hisPath, long fileSize)
    {
        var player = new MediaPlayer { AutoPlay = false };
        player.Source = MediaSource.CreateFromUri(new Uri(tmpWavPath));
        player.MediaOpened += (_, _) => { };

        // ── Icons ──
        var waveIcon = new FontIcon
        {
            Glyph = "",   // Segoe MDL2: WaveformAudio
            FontSize = 56,
            Foreground = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 12)
        };
        var nameBlock = new TextBlock
        {
            Text = Path.GetFileNameWithoutExtension(hisPath),
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 4)
        };
        var sizeBlock = new TextBlock
        {
            Text = $"HIS · {FormatSize(fileSize)}",
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 20)
        };

        // ── Seek slider + time labels ──
        var slider = new Slider { Minimum = 0, Maximum = 1, Value = 0,
                                   HorizontalAlignment = HorizontalAlignment.Stretch };
        var posLabel  = new TextBlock { Text = "0:00", FontFamily = new FontFamily("Consolas"), FontSize = 11 };
        var durLabel  = new TextBlock { Text = "0:00", FontFamily = new FontFamily("Consolas"), FontSize = 11,
                                         HorizontalAlignment = HorizontalAlignment.Right };
        var timeRow = new Grid();
        timeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        timeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        timeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(posLabel, 0);
        Grid.SetColumn(durLabel, 2);
        timeRow.Children.Add(posLabel);
        timeRow.Children.Add(durLabel);
        var seekPanel = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        seekPanel.Children.Add(slider);
        seekPanel.Children.Add(timeRow);

        // ── Play/Pause button ──
        var playIcon  = new FontIcon { Glyph = "", FontSize = 40 };  // Play
        var pauseIcon = new FontIcon { Glyph = "", FontSize = 40 };  // Pause
        var playBtn = new Button
        {
            Content = playIcon,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderBrush = new SolidColorBrush(Colors.Transparent),
            Padding = new Thickness(8),
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 16)
        };

        // ── Export button with flyout ──
        var exportFlyout = new MenuFlyout();
        void AddExportItem(string label, string fmt, string ext)
        {
            var item = new MenuFlyoutItem { Text = label };
            item.Click += async (_, _) =>
            {
                byte[]? data = null;
                try { data = HIPInterop.DecodeHISToFormat(hisPath, fmt); }
                catch { return; }
                if (data != null) await ExportFileAsync(data, hisPath, label, "." + ext);
            };
            exportFlyout.Items.Add(item);
        }
        AddExportItem("OGG Vorbis", "ogg", "ogg");
        AddExportItem("WAV Audio", "wav", "wav");
        AddExportItem("MP3 Audio", "mp3", "mp3");

        var exportBtn = new Button
        {
            Content = "Export…",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
            Flyout = exportFlyout
        };

        // ── Timer for position updates ──
        bool isSeeking = false;
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(100);

        static string FmtDur(TimeSpan t) =>
            $"{(int)t.TotalMinutes}:{t.Seconds:D2}";

        timer.Tick += (_, _) =>
        {
            if (player.PlaybackSession is not { } sess) return;
            if (sess.NaturalDuration == TimeSpan.Zero) return;
            var pos = sess.Position;
            var dur = sess.NaturalDuration;
            posLabel.Text = FmtDur(pos);
            durLabel.Text = FmtDur(dur);
            if (!isSeeking && dur.TotalSeconds > 0)
                slider.Value = pos.TotalSeconds / dur.TotalSeconds;
        };

        bool isPlaying = false;
        void UpdatePlayBtn() =>
            playIcon.Glyph = isPlaying ? "" : "";

        playBtn.Click += (_, _) =>
        {
            if (isPlaying) { player.Pause(); timer.Stop(); isPlaying = false; }
            else           { player.Play();  timer.Start(); isPlaying = true;  }
            UpdatePlayBtn();
        };

        slider.AddHandler(UIElement.PointerPressedEvent,
            new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => { isSeeking = true; }),
            handledEventsToo: true);
        slider.AddHandler(UIElement.PointerReleasedEvent,
            new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) =>
            {
                isSeeking = false;
                if (player.PlaybackSession is { } sess2 && sess2.NaturalDuration.TotalSeconds > 0)
                    sess2.Position = TimeSpan.FromSeconds(slider.Value * sess2.NaturalDuration.TotalSeconds);
            }), handledEventsToo: true);

        player.MediaEnded += (_, _) =>
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                isPlaying = false; timer.Stop();
                UpdatePlayBtn();
                slider.Value = 0;
                posLabel.Text = FmtDur(TimeSpan.Zero);
                player.PlaybackSession.Position = TimeSpan.Zero;
            });
        };

        // ── Bottom status bar ──
        var fileLabel = new TextBlock
        {
            Text = Path.GetFileName(hisPath),
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"],
            Margin = new Thickness(0, 0, 16, 0)
        };
        var barRow = new Grid { Height = 44 };
        barRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        barRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        barRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(exportBtn, 1); Grid.SetColumn(fileLabel, 2);
        barRow.Children.Add(exportBtn); barRow.Children.Add(fileLabel);

        var playerPanel = new StackPanel
        {
            VerticalAlignment   = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            MinWidth = 320, MaxWidth = 480
        };
        playerPanel.Children.Add(waveIcon);
        playerPanel.Children.Add(nameBlock);
        playerPanel.Children.Add(sizeBlock);
        playerPanel.Children.Add(seekPanel);
        playerPanel.Children.Add(playBtn);

        var content = RowLayout(playerPanel, barRow);

        // Cleanup temp file when tab is closed
        if (content is FrameworkElement fe)
            fe.Unloaded += (_, _) =>
            {
                player.Pause();
                timer.Stop();
                player.Source = null;
                try { File.Delete(tmpWavPath); } catch { /* ignore */ }
            };

        return content;
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
