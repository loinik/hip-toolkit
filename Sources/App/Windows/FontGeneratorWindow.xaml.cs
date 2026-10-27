using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;

namespace HIPToolkit;

/// <summary>
/// Bitmap font generator window (HeR-style _SC.lua + atlas PNGs), the
/// Windows twin of FontGeneratorView.swift. The work happens in
/// Sources/Core/BitmapFontGenerator via HIP.Bridge; here GDI is available,
/// so the default hinting renders through GDI exactly as BMFont did.
/// </summary>
public sealed partial class FontGeneratorWindow : Window
{
    // ── Single-instance ───────────────────────────────────────────────────

    private static FontGeneratorWindow? _instance;

    public static void ShowSingle()
    {
        _instance ??= new FontGeneratorWindow();
        _instance.AppWindow.Show();
        _instance.Activate();
    }

    // ── State ─────────────────────────────────────────────────────────────

    private sealed class StyleRow
    {
        public required int Index;
        public required string Title;
        public required CheckBox Enabled;
        public required TextBlock File;
        public required CheckBox SynthBold;
        public required CheckBox SynthItalic;
        public required StackPanel SynthPanel;
        public string? Path;
        public int FaceIndex;
    }

    private static readonly string[] StyleTitles = ["Regular", "Bold", "Italic", "Bold Italic"];
    // HintingBox order → BFHinting: GDI first, it is the exact BMFont path here.
    private static readonly int[] HintingValues = [4, 0, 1, 2, 3];

    private readonly StyleRow[] _rows = new StyleRow[4];
    private readonly List<FontGenInterop.Preset> _presets;
    private readonly List<FontGenInterop.Charset> _charsets;
    private readonly Dictionary<string, CheckBox> _charsetBoxes = [];
    private Dictionary<string, List<FontGenInterop.InstalledFace>> _families = [];
    private string? _preset;
    private FontGenInterop.FontGenResult? _result;
    private int _previewStyle;
    private int _previewVersion;
    // XAML raises SelectionChanged/ValueChanged while InitializeComponent is
    // still wiring the named elements; handlers wait for the constructor.
    private bool _ready;

    public FontGeneratorWindow()
    {
        InitializeComponent();
        Title = S.Get("fontgen_window_title");
        TitleText.Text = Title;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1120, 780));

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.ButtonBackgroundColor         = Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;

        AppWindow.Changed += (sender, args) =>
        {
            if (!args.DidSizeChange) return;
            var s = sender.Size;
            if (s.Width < 860 || s.Height < 600)
                sender.Resize(new Windows.Graphics.SizeInt32(Math.Max(s.Width, 860), Math.Max(s.Height, 600)));
        };
        Closed += (_, _) =>
        {
            _result?.Dispose();
            _result = null;
            _instance = null;
        };

        _presets = FontGenInterop.Presets();
        _charsets = FontGenInterop.Charsets();
        BuildUI();
        _ready = true;
        UpdatePresetUI();
        ShowPreview();
        _ = LoadFamiliesAsync();
    }

    // ── UI construction ───────────────────────────────────────────────────

    private void BuildUI()
    {
        HdrFont.Text = S.Get("fontgen_section_font");
        HdrStyles.Text = S.Get("fontgen_section_styles");
        HdrChars.Text = S.Get("fontgen_section_chars");
        HdrRender.Text = S.Get("fontgen_section_render");

        PresetBox.Header = S.Get("fontgen_preset");
        PresetBox.Items.Add(S.Get("fontgen_preset_custom"));
        foreach (var p in _presets)
            PresetBox.Items.Add($"{p.Name} — {p.Family} {p.PixelSize} px");

        FamilyBox.Header = S.Get("fontgen_family");
        FamilyBox.PlaceholderText = S.Get("fontgen_loading_fonts");
        NameBox.Header = S.Get("fontgen_name");
        NameBox.Text = "Tahoma_12";
        SizeBox.Header = S.Get("fontgen_size_header");
        CellBox.Content = S.Get("fontgen_cell_height");
        BtnDetach.Content = S.Get("fontgen_preset_detach");

        for (int i = 0; i < 4; i++)
        {
            var enabled = new CheckBox { Content = StyleTitles[i], IsChecked = true, MinWidth = 0 };
            var choose = new Button { Content = S.Get("fontgen_choose_file"), Tag = i, Padding = new Thickness(8, 2, 8, 2) };
            choose.Click += ChooseFile_Click;
            var header = new Grid();
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.Children.Add(enabled);
            Grid.SetColumn(choose, 1);
            header.Children.Add(choose);

            var file = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap };
            var synthBold = new CheckBox { Content = S.Get("fontgen_synth_bold"), MinWidth = 0 };
            var synthItalic = new CheckBox { Content = S.Get("fontgen_synth_italic"), MinWidth = 0 };
            var synthPanel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            synthPanel.Children.Add(synthBold);
            synthPanel.Children.Add(synthItalic);

            var block = new StackPanel { Spacing = 2 };
            block.Children.Add(header);
            block.Children.Add(file);
            block.Children.Add(synthPanel);
            StylesPanel.Children.Add(block);

            _rows[i] = new StyleRow
            {
                Index = i, Title = StyleTitles[i], Enabled = enabled, File = file,
                SynthBold = synthBold, SynthItalic = synthItalic, SynthPanel = synthPanel,
            };
            enabled.Click += (_, _) => UpdateStyleRows();
        }

        EncodingBox.Header = S.Get("fontgen_encoding");
        EncodingBox.Items.Add(S.Get("fontgen_encoding_unicode"));
        EncodingBox.Items.Add(S.Get("fontgen_encoding_cp1252"));
        EncodingBox.SelectedIndex = 0;
        var defaults = new HashSet<string> { "cp1252", "fr", "de", "uk", "ru", "kk", "el" };
        foreach (var cs in _charsets)
        {
            var cb = new CheckBox { Content = cs.Title, IsChecked = defaults.Contains(cs.Id), MinWidth = 0 };
            _charsetBoxes[cs.Id] = cb;
            CharsetsPanel.Children.Add(cb);
        }
        ExtraBox.Header = S.Get("fontgen_extra_chars");
        Cp1252Note.Text = S.Get("fontgen_cp1252_note");

        HintingBox.Header = S.Get("fontgen_hinting");
        HintingBox.Items.Add(S.Get("fontgen_hint_gdi"));
        HintingBox.Items.Add(S.Get("fontgen_hint_classic"));
        HintingBox.Items.Add(S.Get("fontgen_hint_modern"));
        HintingBox.Items.Add(S.Get("fontgen_hint_light"));
        HintingBox.Items.Add(S.Get("fontgen_hint_none"));
        HintingBox.SelectedIndex = 0;
        AntialiasBox.Header = S.Get("fontgen_antialias");
        AntialiasBox.Items.Add(S.Get("fontgen_aa_gdi"));
        AntialiasBox.Items.Add(S.Get("fontgen_aa_smooth"));
        AntialiasBox.Items.Add(S.Get("fontgen_aa_none"));
        AntialiasBox.SelectedIndex = 0;
        WhiteBox.Content = S.Get("fontgen_white_rgb");
        SpacingBox.Header = S.Get("fontgen_spacing_header");
        PaddingBox.Header = S.Get("fontgen_padding_header");
        KerningBox.Content = S.Get("fontgen_kerning");
        CifBox.Content = S.Get("fontgen_export_cif");
        BtnGenerate.Content = S.Get("fontgen_generate");
        BtnExport.Content = S.Get("fontgen_export");

        ScaleBox.Header = null;
        ToolTipService.SetToolTip(ScaleBox, S.Get("fontgen_scale"));
        SampleBox.Header = S.Get("fontgen_sample");
        SampleBox.Text = "The quick brown fox — «Ёжик» в тумане. Қазақ тілі. Ελληνικά. Größe, ça va?";
        MissingHeader.Text = S.Get("fontgen_missing");
        HintText.Text = S.Get("fontgen_hint");

        // Start on the Tahoma_12 preset, like the macOS window.
        var idx = _presets.FindIndex(p => p.Name == "Tahoma_12");
        PresetBox.SelectedIndex = idx + 1;   // handler is idle until _ready: set what it would
        if (idx >= 0)
        {
            _preset = _presets[idx].Name;
            NameBox.Text = _preset;
            SizeBox.Value = _presets[idx].PixelSize;
        }
        UpdateStyleRows();
    }

    // ── Installed fonts ───────────────────────────────────────────────────

    private async Task LoadFamiliesAsync()
    {
        List<FontGenInterop.InstalledFace> faces;
        try { faces = await Task.Run(FontGenInterop.ListInstalled); }
        catch (Exception ex) { ShowError(ex.Message); return; }

        _families = faces.GroupBy(f => f.Family, StringComparer.OrdinalIgnoreCase)
                         .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);
        FamilyBox.ItemsSource = _families.Keys.OrderBy(k => k, StringComparer.OrdinalIgnoreCase).ToList();
        FamilyBox.PlaceholderText = "";

        var wanted = _preset != null ? _presets.First(p => p.Name == _preset).Family : "Tahoma";
        SelectFamily(wanted, reportMissing: _preset != null);
    }

    private bool SelectFamily(string family, bool reportMissing)
    {
        if (FamilyBox.ItemsSource is not List<string> list) return false;
        var match = list.FirstOrDefault(f => string.Equals(f, family, StringComparison.OrdinalIgnoreCase));
        if (match == null)
        {
            if (reportMissing) ShowError(S.Fmt("fontgen_font_missing", family));
            return false;
        }
        if (Equals(FamilyBox.SelectedItem, match)) LoadFamily(match);
        else FamilyBox.SelectedItem = match;   // → FamilyBox_SelectionChanged → LoadFamily
        return true;
    }

    /// <summary>
    /// The best face per HeR style (Regular, Bold, Italic, BoldItalic); null
    /// where the family has none (the generator then synthesizes, as GDI did).
    /// Narrow, condensed, black or light members lose against the plain one.
    /// </summary>
    private static FontGenInterop.InstalledFace?[] StyleFiles(List<FontGenInterop.InstalledFace> faces)
    {
        var best = new (int Score, FontGenInterop.InstalledFace Face)?[4];
        string[] bad = ["narrow", "condensed", "black", "light", "medium", "semibold", "demi", "rounded"];
        foreach (var f in faces)
        {
            bool bold = f.Bold || f.Weight >= 600;
            int slot = (bold ? 1 : 0) + (f.Italic ? 2 : 0);
            int score = 100 - Math.Abs(f.Weight - (bold ? 700 : 400)) / 10;
            if (f.Width != 5) score -= 40;
            var lower = f.Style.ToLowerInvariant();
            foreach (var b in bad)
                if (lower.Contains(b)) score -= 40;
            if (best[slot] == null || score > best[slot]!.Value.Score) best[slot] = (score, f);
        }
        return best.Select(b => b?.Face).ToArray();
    }

    private void LoadFamily(string family)
    {
        if (!_families.TryGetValue(family, out var faces)) return;
        var files = StyleFiles(faces);
        for (int i = 0; i < 4; i++)
        {
            _rows[i].Path = files[i]?.Path;
            _rows[i].FaceIndex = files[i]?.FaceIndex ?? 0;
            _rows[i].SynthBold.IsChecked = false;
            _rows[i].SynthItalic.IsChecked = false;
        }
        UpdateStyleRows();
    }

    private void UpdateStyleRows()
    {
        foreach (var r in _rows)
        {
            bool derivedFromBold = r.Index == 3 && _rows[1].Path != null && _rows[1].Enabled.IsChecked == true;
            r.File.Text = r.Path != null
                ? System.IO.Path.GetFileName(r.Path) + (r.FaceIndex > 0 ? $" #{r.FaceIndex}" : "")
                : S.Get(derivedFromBold ? "fontgen_synthesized_bold" : "fontgen_synthesized");
            if (r.Path == null) r.File.Foreground = new SolidColorBrush(Colors.Orange);
            else r.File.ClearValue(TextBlock.ForegroundProperty);
            r.File.Opacity = r.Path == null ? 1.0 : 0.7;
            r.SynthPanel.Visibility = r.Path != null && r.Index > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    // ── Presets ───────────────────────────────────────────────────────────

    private void PresetBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        int i = PresetBox.SelectedIndex;
        if (i <= 0)
        {
            _preset = null;
            UpdatePresetUI();
            return;
        }
        var p = _presets[i - 1];
        _preset = p.Name;
        NameBox.Text = p.Name;
        SizeBox.Value = p.PixelSize;
        CellBox.IsChecked = true;
        HideError();
        if (_families.Count > 0) SelectFamily(p.Family, reportMissing: true);
        UpdatePresetUI();
    }

    private void Detach_Click(object sender, RoutedEventArgs e) => PresetBox.SelectedIndex = 0;

    private void UpdatePresetUI()
    {
        bool custom = _preset == null;
        CustomSizePanel.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
        PresetNotePanel.Visibility = custom ? Visibility.Collapsed : Visibility.Visible;
        if (!custom) PresetNote.Text = S.Fmt("fontgen_preset_active", _preset!);
        // A preset pins the measured look; hinting stays the user's (GDI here).
        AntialiasBox.IsEnabled = custom;
        WhiteBox.IsEnabled = custom;
        SpacingBox.IsEnabled = custom;
        PaddingBox.IsEnabled = custom;
    }

    private void FamilyBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        if (FamilyBox.SelectedItem is string f) LoadFamily(f);
    }

    private void EncodingBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        Cp1252Note.Visibility = EncodingBox.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void ChooseFile_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: int i }) return;
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".ttf");
        picker.FileTypeFilter.Add(".otf");
        picker.FileTypeFilter.Add(".ttc");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var file = await picker.PickSingleFileAsync();
        if (file == null) return;
        _rows[i].Path = file.Path;
        _rows[i].FaceIndex = 0;
        UpdateStyleRows();
    }

    // ── Generate / export ─────────────────────────────────────────────────

    private static int IntOf(NumberBox b, int fallback) =>
        double.IsNaN(b.Value) ? fallback : (int)Math.Round(b.Value);

    private JsonObject Options()
    {
        var styles = new JsonArray();
        foreach (var r in _rows)
            styles.Add(new JsonObject
            {
                ["path"] = r.Path ?? "",
                ["faceIndex"] = r.FaceIndex,
                ["synthBold"] = r.SynthBold.IsChecked == true,
                ["synthItalic"] = r.SynthItalic.IsChecked == true,
                ["enabled"] = r.Enabled.IsChecked == true,
            });
        var charsets = new JsonArray();
        foreach (var (id, cb) in _charsetBoxes)
            if (cb.IsChecked == true) charsets.Add(id);
        return new JsonObject
        {
            ["name"] = NameBox.Text.Trim(),
            ["pixelSize"] = IntOf(SizeBox, 12),
            ["cellHeight"] = CellBox.IsChecked == true,
            ["preset"] = _preset ?? "",
            ["styles"] = styles,
            ["unicode"] = EncodingBox.SelectedIndex == 0,
            ["charsets"] = charsets,
            ["extra"] = ExtraBox.Text,
            ["hinting"] = HintingValues[Math.Max(0, HintingBox.SelectedIndex)],
            ["antialias"] = Math.Max(0, AntialiasBox.SelectedIndex),
            ["whiteRGB"] = WhiteBox.IsChecked == true,
            ["padding"] = IntOf(PaddingBox, 0),
            ["kerning"] = KerningBox.IsChecked == true,
            ["spacing"] = IntOf(SpacingBox, 0),
        };
    }

    private async void Generate_Click(object sender, RoutedEventArgs e)
    {
        HideError();
        var options = Options();
        BtnGenerate.IsEnabled = false;
        try
        {
            var r = await Task.Run(() => FontGenInterop.Generate(options));
            _result?.Dispose();
            _result = r;
            var present = r.Styles.Where(s => s.Present).ToList();
            var missing = present.SelectMany(s => s.Missing.EnumerateRunes()).Distinct().Count();
            StatusText.Text = S.Fmt("fontgen_status", present.FirstOrDefault()?.GlyphCount ?? 0, present.Count, missing);
            BtnExport.IsEnabled = true;
        }
        catch (Exception ex)
        {
            _result?.Dispose();
            _result = null;
            BtnExport.IsEnabled = false;
            ShowError(ex.Message);
        }
        finally { BtnGenerate.IsEnabled = true; }
        ShowPreview();
    }

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        if (_result == null) return;
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder == null) return;
        try
        {
            var dir = folder.Path;
            var name = NameBox.Text.Trim();
            var luaPath = System.IO.Path.Combine(dir, $"{name}_SC.lua");
            await File.WriteAllTextAsync(luaPath, _result.Lua, new System.Text.UTF8Encoding(false));
            int written = 1;
            for (int i = 0; i < 4; i++)
            {
                var st = _result.Styles[i];
                if (!st.Present) continue;
                var pngPath = System.IO.Path.Combine(dir, $"{st.OvlName}.png");
                await File.WriteAllBytesAsync(pngPath, _result.Png(i));
                written++;
                if (CifBox.IsChecked == true)
                    await File.WriteAllBytesAsync(System.IO.Path.Combine(dir, $"{st.OvlName}.cif"),
                                                  HIPInterop.EncodePNG(pngPath, 2));
            }
            if (CifBox.IsChecked == true)
                await File.WriteAllBytesAsync(System.IO.Path.Combine(dir, $"{name}_SC.cif"),
                                              HIPInterop.EncodeLua(luaPath, compileLua: true));
            StatusText.Text = S.Fmt("fontgen_exported", written, dir);
        }
        catch (Exception ex) { ShowError(ex.Message); }
    }

    // ── Preview ───────────────────────────────────────────────────────────

    private void PreviewStyleBar_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (!_ready) return;
        if (sender.SelectedItem?.Tag is string t && int.TryParse(t, out var i)) _previewStyle = i;
        ShowPreview();
    }

    private void ScaleBox_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_ready) ShowPreview();
    }

    private void SampleBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_ready) ShowSample();
    }

    private int Scale => Math.Clamp(IntOf(ScaleBox, 2), 1, 6);

    private FontGenInterop.StyleInfo? CurrentStyle =>
        _result != null && _result.Styles[_previewStyle].Present ? _result.Styles[_previewStyle] : null;

    private void ShowPreview()
    {
        var st = CurrentStyle;
        HintText.Visibility = st == null ? Visibility.Visible : Visibility.Collapsed;
        AtlasBorder.Visibility = st == null ? Visibility.Collapsed : Visibility.Visible;
        if (st == null)
        {
            SampleImage.Source = null;
            AtlasImage.Source = null;
            AtlasInfo.Text = "";
            MissingPanel.Visibility = Visibility.Collapsed;
            return;
        }
        AtlasInfo.Text = S.Fmt("fontgen_atlas_info", st.OvlName, st.Width, st.Height, st.GlyphCount, st.LineHeight);
        MissingText.Text = st.Missing;
        MissingPanel.Visibility = st.Missing.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowSample();
        _ = ShowAtlasAsync(_previewStyle, Scale);
    }

    private void ShowSample()
    {
        if (CurrentStyle == null || _result == null) return;
        try
        {
            var (rgba, w, h) = _result.Sample(_previewStyle, SampleBox.Text.Replace("\r\n", "\n").Replace('\r', '\n'), 0, Scale);
            // White text on transparent → premultiplied BGRA is (a, a, a, a).
            var bgra = new byte[rgba.Length];
            for (int i = 0; i < rgba.Length; i += 4)
                bgra[i] = bgra[i + 1] = bgra[i + 2] = bgra[i + 3] = rgba[i + 3];
            SampleImage.Source = ToBitmap(bgra, w, h);
        }
        catch (Exception ex) { ShowError(ex.Message); }
    }

    /// <summary>The atlas as stored (RGB = alpha or white, plus the colour
    /// bleed), nearest-neighbour zoomed: Image has no point filtering.</summary>
    private async Task ShowAtlasAsync(int style, int scale)
    {
        if (_result == null) return;
        int version = ++_previewVersion;
        try
        {
            var png = _result.Png(style);
            using var ms = new InMemoryRandomAccessStream();
            await ms.WriteAsync(png.AsBuffer());
            ms.Seek(0);
            var dec = await BitmapDecoder.CreateAsync(ms);
            var data = await dec.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                                                   new BitmapTransform(), ExifOrientationMode.IgnoreExifOrientation,
                                                   ColorManagementMode.DoNotColorManage);
            if (version != _previewVersion) return;
            byte[] src = data.DetachPixelData();
            int w = (int)dec.PixelWidth, h = (int)dec.PixelHeight, W = w * scale, H = h * scale;
            var dst = new byte[W * H * 4];
            for (int y = 0; y < H; y++)
            {
                int sy = y / scale;
                for (int x = 0; x < W; x++)
                    System.Buffer.BlockCopy(src, (sy * w + x / scale) * 4, dst, (y * W + x) * 4, 4);
            }
            AtlasImage.Source = ToBitmap(dst, W, H);
        }
        catch (Exception ex) { ShowError(ex.Message); }
    }

    private static WriteableBitmap ToBitmap(byte[] bgraPremultiplied, int w, int h)
    {
        var wb = new WriteableBitmap(w, h);
        using (var s = wb.PixelBuffer.AsStream())
            s.Write(bgraPremultiplied, 0, bgraPremultiplied.Length);
        wb.Invalidate();
        return wb;
    }

    // ── Messages ──────────────────────────────────────────────────────────

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }

    private void HideError() => ErrorText.Visibility = Visibility.Collapsed;
}
